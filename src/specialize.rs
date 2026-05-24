use crate::ast::{Decl, Expr, Pattern, Program};
use crate::ctfe::{CtfeError, CtfeEvaluator, CtfeValue};
use crate::span::Span;
use crate::types::Type;
use std::collections::{HashMap, HashSet};

#[derive(Debug, Clone)]
pub struct SpecializeError {
    pub msg: String,
    pub span: Span,
}

impl SpecializeError {
    fn at(msg: impl Into<String>, span: Span) -> Self {
        SpecializeError {
            msg: msg.into(),
            span,
        }
    }
}

#[derive(Debug, Clone)]
struct Template {
    name: String,
    params: Vec<(String, Type)>,
    comptime_params: Vec<usize>,
    ret: Type,
    body: Expr,
}

pub fn specialize_program(program: &Program) -> Result<Program, SpecializeError> {
    let mut pass = Specializer::new(program)?;
    pass.specialize(program)
}

struct Specializer {
    templates: HashMap<String, Template>,
    generated: Vec<Decl>,
    cache: HashMap<String, String>,
}

impl Specializer {
    fn new(program: &Program) -> Result<Self, SpecializeError> {
        let mut templates = HashMap::new();
        for decl in &program.decls {
            if let Decl::DefFn {
                name,
                params,
                comptime_params,
                ret,
                body,
            } = decl
            {
                validate_params(params, comptime_params, body.span())?;
                if !comptime_params.is_empty() {
                    templates.insert(
                        name.clone(),
                        Template {
                            name: name.clone(),
                            params: params.clone(),
                            comptime_params: comptime_params.clone(),
                            ret: ret.clone(),
                            body: body.clone(),
                        },
                    );
                }
            }
        }
        Ok(Specializer {
            templates,
            generated: Vec::new(),
            cache: HashMap::new(),
        })
    }

    fn specialize(&mut self, program: &Program) -> Result<Program, SpecializeError> {
        let mut decls = Vec::new();
        for decl in &program.decls {
            match decl {
                Decl::Def { name, ty, value } => {
                    decls.push(Decl::Def {
                        name: name.clone(),
                        ty: ty.clone(),
                        value: self.rewrite_expr(value)?,
                    });
                }
                Decl::DefFn {
                    name,
                    params,
                    comptime_params,
                    ret,
                    body,
                } => {
                    if comptime_params.is_empty() {
                        let shadowed =
                            self.shadow_templates(params.iter().map(|(name, _)| name.clone()));
                        let body = self.rewrite_expr(body);
                        self.restore_templates(shadowed);
                        decls.push(Decl::DefFn {
                            name: name.clone(),
                            params: params.clone(),
                            comptime_params: Vec::new(),
                            ret: ret.clone(),
                            body: body?,
                        });
                    }
                }
                Decl::Extern { .. }
                | Decl::DefEnum { .. }
                | Decl::DefStruct { .. }
                | Decl::Import(_) => decls.push(decl.clone()),
            }
        }
        decls.extend(self.generated.clone());
        Ok(Program { decls })
    }

    fn rewrite_expr(&mut self, expr: &Expr) -> Result<Expr, SpecializeError> {
        match expr {
            Expr::Spanned { expr, span } => Ok(Expr::spanned(self.rewrite_expr(expr)?, *span)),
            Expr::Var(name) if self.templates.contains_key(name) => Err(SpecializeError::at(
                format!(
                    "function '{}' has comptime parameters and must be called directly",
                    name
                ),
                expr.span(),
            )),
            Expr::Var(_) | Expr::Literal(_) | Expr::TypeLiteral { .. } => Ok(expr.clone()),
            Expr::Binary { op, lhs, rhs } => Ok(Expr::Binary {
                op: *op,
                lhs: Box::new(self.rewrite_expr(lhs)?),
                rhs: Box::new(self.rewrite_expr(rhs)?),
            }),
            Expr::Unary { op, expr: inner } => Ok(Expr::Unary {
                op: *op,
                expr: Box::new(self.rewrite_expr(inner)?),
            }),
            Expr::Call { func, args } => {
                if let Expr::Var(name) = func.unspan()
                    && self.templates.contains_key(name)
                {
                    return self.rewrite_specialized_call(name, args, expr.span());
                }
                Ok(Expr::Call {
                    func: Box::new(self.rewrite_expr(func)?),
                    args: args
                        .iter()
                        .map(|arg| self.rewrite_expr(arg))
                        .collect::<Result<_, _>>()?,
                })
            }
            Expr::Comptime { expr: inner } => Ok(Expr::Comptime {
                expr: Box::new(self.rewrite_expr(inner)?),
            }),
            Expr::If {
                cond,
                then_branch,
                else_branch,
            } => Ok(Expr::If {
                cond: Box::new(self.rewrite_expr(cond)?),
                then_branch: Box::new(self.rewrite_expr(then_branch)?),
                else_branch: Box::new(self.rewrite_expr(else_branch)?),
            }),
            Expr::Let { bindings, body } => Ok(Expr::Let {
                bindings: {
                    let mut rewritten = Vec::new();
                    let mut shadowed = Vec::new();
                    for (name, ty, value) in bindings {
                        rewritten.push((name.clone(), ty.clone(), self.rewrite_expr(value)?));
                        if let Some(template) = self.templates.remove(name) {
                            shadowed.push((name.clone(), template));
                        }
                    }
                    self.restore_templates(shadowed);
                    rewritten
                },
                body: {
                    let shadowed =
                        self.shadow_templates(bindings.iter().map(|(name, _, _)| name.clone()));
                    let body = self.rewrite_expr(body);
                    self.restore_templates(shadowed);
                    Box::new(body?)
                },
            }),
            Expr::Lambda { params, ret, body } => {
                let shadowed = self.shadow_templates(params.iter().map(|(name, _)| name.clone()));
                let body = self.rewrite_expr(body);
                self.restore_templates(shadowed);
                Ok(Expr::Lambda {
                    params: params.clone(),
                    ret: ret.clone(),
                    body: Box::new(body?),
                })
            }
            Expr::Tuple(elems) => Ok(Expr::Tuple(
                elems
                    .iter()
                    .map(|elem| self.rewrite_expr(elem))
                    .collect::<Result<_, _>>()?,
            )),
            Expr::TupleRef { expr: inner, index } => Ok(Expr::TupleRef {
                expr: Box::new(self.rewrite_expr(inner)?),
                index: *index,
            }),
            Expr::Array(elems) => Ok(Expr::Array(
                elems
                    .iter()
                    .map(|elem| self.rewrite_expr(elem))
                    .collect::<Result<_, _>>()?,
            )),
            Expr::MakeArray { elem_ty, len } => Ok(Expr::MakeArray {
                elem_ty: elem_ty.clone(),
                len: Box::new(self.rewrite_expr(len)?),
            }),
            Expr::ArrayRef { expr: inner, index } => Ok(Expr::ArrayRef {
                expr: Box::new(self.rewrite_expr(inner)?),
                index: Box::new(self.rewrite_expr(index)?),
            }),
            Expr::ArraySet {
                expr: inner,
                index,
                value,
            } => Ok(Expr::ArraySet {
                expr: Box::new(self.rewrite_expr(inner)?),
                index: Box::new(self.rewrite_expr(index)?),
                value: Box::new(self.rewrite_expr(value)?),
            }),
            Expr::While { cond, body } => Ok(Expr::While {
                cond: Box::new(self.rewrite_expr(cond)?),
                body: Box::new(self.rewrite_expr(body)?),
            }),
            Expr::Begin(exprs) => Ok(Expr::Begin(
                exprs
                    .iter()
                    .map(|inner| self.rewrite_expr(inner))
                    .collect::<Result<_, _>>()?,
            )),
            Expr::Set(name, value) => {
                Ok(Expr::Set(name.clone(), Box::new(self.rewrite_expr(value)?)))
            }
            Expr::Ann { expr: inner, ty } => Ok(Expr::Ann {
                expr: Box::new(self.rewrite_expr(inner)?),
                ty: ty.clone(),
            }),
            Expr::Cast { expr: inner, ty } => Ok(Expr::Cast {
                expr: Box::new(self.rewrite_expr(inner)?),
                ty: ty.clone(),
            }),
            Expr::Match { scrutinee, arms } => Ok(Expr::Match {
                scrutinee: Box::new(self.rewrite_expr(scrutinee)?),
                arms: arms
                    .iter()
                    .map(|(pat, body)| {
                        let mut bindings = HashSet::new();
                        collect_pattern_bindings(pat, &mut bindings);
                        let shadowed = self.shadow_templates(bindings);
                        let body = self.rewrite_expr(body);
                        self.restore_templates(shadowed);
                        Ok((pat.clone(), body?))
                    })
                    .collect::<Result<_, SpecializeError>>()?,
            }),
            Expr::Foreach {
                index,
                index_ty,
                start,
                end,
                body,
            } => {
                let shadowed = self.shadow_templates(std::iter::once(index.clone()));
                let body = self.rewrite_expr(body);
                self.restore_templates(shadowed);
                Ok(Expr::Foreach {
                    index: index.clone(),
                    index_ty: index_ty.clone(),
                    start: Box::new(self.rewrite_expr(start)?),
                    end: Box::new(self.rewrite_expr(end)?),
                    body: Box::new(body?),
                })
            }
            Expr::SpmdReduce {
                op,
                index,
                index_ty,
                start,
                end,
                init,
                value,
            } => {
                let shadowed = self.shadow_templates(std::iter::once(index.clone()));
                let value = self.rewrite_expr(value);
                self.restore_templates(shadowed);
                Ok(Expr::SpmdReduce {
                    op: *op,
                    index: index.clone(),
                    index_ty: index_ty.clone(),
                    start: Box::new(self.rewrite_expr(start)?),
                    end: Box::new(self.rewrite_expr(end)?),
                    init: Box::new(self.rewrite_expr(init)?),
                    value: Box::new(value?),
                })
            }
            Expr::StructGet { expr: inner, field } => Ok(Expr::StructGet {
                expr: Box::new(self.rewrite_expr(inner)?),
                field: field.clone(),
            }),
            Expr::WithRegion { region, body } => Ok(Expr::WithRegion {
                region: region.clone(),
                body: body
                    .iter()
                    .map(|inner| self.rewrite_expr(inner))
                    .collect::<Result<_, _>>()?,
            }),
        }
    }

    fn rewrite_specialized_call(
        &mut self,
        name: &str,
        args: &[Expr],
        call_span: Span,
    ) -> Result<Expr, SpecializeError> {
        let template = self.templates.get(name).cloned().unwrap();
        if args.len() != template.params.len() {
            return Err(SpecializeError::at(
                format!(
                    "function '{}' expects {} arguments including comptime parameters, got {}",
                    name,
                    template.params.len(),
                    args.len()
                ),
                call_span,
            ));
        }

        let comptime_set: HashSet<usize> = template.comptime_params.iter().copied().collect();
        let mut values = Vec::new();
        let mut runtime_args = Vec::new();
        for (idx, (arg, (param_name, param_ty))) in
            args.iter().zip(template.params.iter()).enumerate()
        {
            if comptime_set.contains(&idx) {
                let value = CtfeEvaluator::new().eval(arg).map_err(|err| match err {
                    CtfeError::Message { msg, span } => SpecializeError::at(
                        format!(
                            "comptime argument '{}' for function '{}' is not compile-time-known: {}",
                            param_name, name, msg
                        ),
                        span,
                    ),
                })?;
                if is_type_kind_param(param_ty) {
                    // A `type`-kind comptime parameter accepts only a
                    // compile-time-known type value, e.g. `(type i64)`. A scalar
                    // (runtime-representable) value here is a kind mismatch.
                    if !matches!(value, CtfeValue::Type(_)) {
                        return Err(SpecializeError::at(
                            format!(
                                "comptime argument '{}' for function '{}' must be a type value \
                                 such as `(type i64)`, got a {} value",
                                param_name,
                                name,
                                value.type_label()
                            ),
                            arg.span(),
                        ));
                    }
                } else if value.runtime_ty().as_ref() != Some(param_ty) {
                    return Err(SpecializeError::at(
                        format!(
                            "comptime argument '{}' for function '{}' has type {}, expected {}",
                            param_name,
                            name,
                            value.type_label(),
                            param_ty
                        ),
                        arg.span(),
                    ));
                }
                values.push(value);
            } else {
                runtime_args.push(self.rewrite_expr(arg)?);
            }
        }

        let specialized_name = self.ensure_specialization(&template, &values, call_span)?;
        Ok(Expr::Call {
            func: Box::new(Expr::Var(specialized_name)),
            args: runtime_args,
        })
    }

    fn ensure_specialization(
        &mut self,
        template: &Template,
        values: &[CtfeValue],
        call_span: Span,
    ) -> Result<String, SpecializeError> {
        let key = specialization_key(&template.name, values);
        if let Some(name) = self.cache.get(&key) {
            return Ok(name.clone());
        }

        let generated_name = format!(
            "__tl_specialized_{}_{}",
            safe_symbol_fragment(&template.name),
            stable_hash_hex(&key)
        );
        self.cache.insert(key, generated_name.clone());

        let comptime_set: HashSet<usize> = template.comptime_params.iter().copied().collect();
        let mut substitutions = HashMap::new();
        let mut type_substitutions = HashMap::new();
        let mut value_idx = 0;
        let mut runtime_params = Vec::new();
        for (idx, (param_name, param_ty)) in template.params.iter().enumerate() {
            if comptime_set.contains(&idx) {
                let Some(value) = values.get(value_idx) else {
                    return Err(SpecializeError::at(
                        "internal specialization value mismatch",
                        call_span,
                    ));
                };
                if is_type_kind_param(param_ty) {
                    let CtfeValue::Type(ty) = value else {
                        return Err(SpecializeError::at(
                            "internal specialization value mismatch",
                            call_span,
                        ));
                    };
                    type_substitutions.insert(param_name.clone(), ty.clone());
                } else {
                    substitutions.insert(param_name.clone(), value.clone());
                }
                value_idx += 1;
            } else {
                runtime_params.push((param_name.clone(), param_ty.clone()));
            }
        }

        // Bind type-valued comptime parameters into the selected type position
        // (array element type) first, rejecting any other use, then substitute
        // scalar comptime parameters into the runtime expression tree.
        let substituted = substitute_type_params(&template.body, &type_substitutions)?;
        let substituted =
            substitute_comptime_params(&substituted, &substitutions, &HashSet::new())?;
        let shadowed = self.shadow_templates(runtime_params.iter().map(|(name, _)| name.clone()));
        let body = self.rewrite_expr(&substituted);
        self.restore_templates(shadowed);
        let body = body?;
        self.generated.push(Decl::DefFn {
            name: generated_name.clone(),
            params: runtime_params,
            comptime_params: Vec::new(),
            ret: template.ret.clone(),
            body,
        });
        Ok(generated_name)
    }

    fn shadow_templates<I>(&mut self, names: I) -> Vec<(String, Template)>
    where
        I: IntoIterator<Item = String>,
    {
        let mut removed = Vec::new();
        for name in names {
            if let Some(template) = self.templates.remove(&name) {
                removed.push((name, template));
            }
        }
        removed
    }

    fn restore_templates(&mut self, removed: Vec<(String, Template)>) {
        for (name, template) in removed {
            self.templates.insert(name, template);
        }
    }
}

fn validate_params(
    params: &[(String, Type)],
    comptime_params: &[usize],
    span: Span,
) -> Result<(), SpecializeError> {
    let mut names = HashSet::new();
    for (name, _) in params {
        if !names.insert(name) {
            return Err(SpecializeError::at(
                format!("duplicate parameter name '{}'", name),
                span,
            ));
        }
    }

    let mut indexes = HashSet::new();
    for idx in comptime_params {
        if *idx >= params.len() || !indexes.insert(*idx) {
            return Err(SpecializeError::at(
                "invalid comptime parameter metadata",
                span,
            ));
        }
        let (_, ty) = &params[*idx];
        if !is_supported_comptime_param_type(ty) {
            return Err(SpecializeError::at(
                format!(
                    "unsupported comptime parameter type {}; supported scalar types are i64, f64, bool, char, and unit, or the `type` kind for type-valued parameters",
                    ty
                ),
                span,
            ));
        }
    }
    Ok(())
}

/// Whether a comptime parameter annotation denotes the `type` *kind* — i.e. the
/// parameter is type-valued (`[comptime T : type]`) rather than carrying a
/// runtime scalar value. The `type` keyword parses as `Type::Var("type")` in
/// type position (it is not a runtime value type), which is how the kind is
/// distinguished from a nominal `Type::Var` naming a declared enum/struct.
fn is_type_kind_param(ty: &Type) -> bool {
    matches!(ty, Type::Var(name) if name == "type")
}

fn is_supported_comptime_param_type(ty: &Type) -> bool {
    is_type_kind_param(ty)
        || matches!(
            ty,
            Type::I64 | Type::F64 | Type::Bool | Type::Char | Type::Unit
        )
}

fn specialization_key(name: &str, values: &[CtfeValue]) -> String {
    let mut key = String::new();
    key.push_str(name);
    key.push('(');
    for (idx, value) in values.iter().enumerate() {
        if idx > 0 {
            key.push(',');
        }
        key.push_str(&value.key_fragment());
    }
    key.push(')');
    key
}

fn stable_hash_hex(text: &str) -> String {
    let mut hash: u64 = 0xcbf29ce484222325;
    for byte in text.bytes() {
        hash ^= byte as u64;
        hash = hash.wrapping_mul(0x100000001b3);
    }
    format!("{hash:016x}")
}

fn safe_symbol_fragment(text: &str) -> String {
    let mut out = String::new();
    for ch in text.chars() {
        if ch.is_ascii_alphanumeric() || ch == '_' {
            out.push(ch);
        } else if ch == '-' {
            out.push('_');
        } else {
            out.push_str("_x");
            out.push_str(&format!("{:x}", ch as u32));
        }
    }
    if out.is_empty() { "fn".into() } else { out }
}

fn literal_expr(value: &CtfeValue, span: Span) -> Result<Expr, SpecializeError> {
    match value.to_literal() {
        Some(lit) => Ok(Expr::spanned(Expr::Literal(lit), span)),
        None => Err(SpecializeError::at(
            "cannot substitute compile-time type value into runtime expression",
            span,
        )),
    }
}

fn substitute_comptime_params(
    expr: &Expr,
    values: &HashMap<String, CtfeValue>,
    shadowed: &HashSet<String>,
) -> Result<Expr, SpecializeError> {
    match expr {
        Expr::Spanned { expr, span } => Ok(Expr::spanned(
            substitute_comptime_params(expr, values, shadowed)?,
            *span,
        )),
        Expr::Var(name) if !shadowed.contains(name) => {
            if let Some(value) = values.get(name) {
                literal_expr(value, expr.span())
            } else {
                Ok(expr.clone())
            }
        }
        Expr::Var(_) | Expr::Literal(_) | Expr::TypeLiteral { .. } => Ok(expr.clone()),
        Expr::Binary { op, lhs, rhs } => Ok(Expr::Binary {
            op: *op,
            lhs: Box::new(substitute_comptime_params(lhs, values, shadowed)?),
            rhs: Box::new(substitute_comptime_params(rhs, values, shadowed)?),
        }),
        Expr::Unary { op, expr: inner } => Ok(Expr::Unary {
            op: *op,
            expr: Box::new(substitute_comptime_params(inner, values, shadowed)?),
        }),
        Expr::Call { func, args } => Ok(Expr::Call {
            func: Box::new(substitute_comptime_params(func, values, shadowed)?),
            args: args
                .iter()
                .map(|arg| substitute_comptime_params(arg, values, shadowed))
                .collect::<Result<_, _>>()?,
        }),
        Expr::Comptime { expr: inner } => Ok(Expr::Comptime {
            expr: Box::new(substitute_comptime_params(inner, values, shadowed)?),
        }),
        Expr::If {
            cond,
            then_branch,
            else_branch,
        } => Ok(Expr::If {
            cond: Box::new(substitute_comptime_params(cond, values, shadowed)?),
            then_branch: Box::new(substitute_comptime_params(then_branch, values, shadowed)?),
            else_branch: Box::new(substitute_comptime_params(else_branch, values, shadowed)?),
        }),
        Expr::Let { bindings, body } => {
            let mut rewritten_bindings = Vec::new();
            let mut current_shadowed = shadowed.clone();
            for (name, ty, value) in bindings {
                rewritten_bindings.push((
                    name.clone(),
                    ty.clone(),
                    substitute_comptime_params(value, values, &current_shadowed)?,
                ));
                current_shadowed.insert(name.clone());
            }
            Ok(Expr::Let {
                bindings: rewritten_bindings,
                body: Box::new(substitute_comptime_params(body, values, &current_shadowed)?),
            })
        }
        Expr::Lambda { params, ret, body } => {
            let mut body_shadowed = shadowed.clone();
            for (name, _) in params {
                body_shadowed.insert(name.clone());
            }
            Ok(Expr::Lambda {
                params: params.clone(),
                ret: ret.clone(),
                body: Box::new(substitute_comptime_params(body, values, &body_shadowed)?),
            })
        }
        Expr::Tuple(elems) => Ok(Expr::Tuple(
            elems
                .iter()
                .map(|elem| substitute_comptime_params(elem, values, shadowed))
                .collect::<Result<_, _>>()?,
        )),
        Expr::TupleRef { expr: inner, index } => Ok(Expr::TupleRef {
            expr: Box::new(substitute_comptime_params(inner, values, shadowed)?),
            index: *index,
        }),
        Expr::Array(elems) => Ok(Expr::Array(
            elems
                .iter()
                .map(|elem| substitute_comptime_params(elem, values, shadowed))
                .collect::<Result<_, _>>()?,
        )),
        Expr::MakeArray { elem_ty, len } => Ok(Expr::MakeArray {
            elem_ty: elem_ty.clone(),
            len: Box::new(substitute_comptime_params(len, values, shadowed)?),
        }),
        Expr::ArrayRef { expr: inner, index } => Ok(Expr::ArrayRef {
            expr: Box::new(substitute_comptime_params(inner, values, shadowed)?),
            index: Box::new(substitute_comptime_params(index, values, shadowed)?),
        }),
        Expr::ArraySet {
            expr: inner,
            index,
            value,
        } => Ok(Expr::ArraySet {
            expr: Box::new(substitute_comptime_params(inner, values, shadowed)?),
            index: Box::new(substitute_comptime_params(index, values, shadowed)?),
            value: Box::new(substitute_comptime_params(value, values, shadowed)?),
        }),
        Expr::While { cond, body } => Ok(Expr::While {
            cond: Box::new(substitute_comptime_params(cond, values, shadowed)?),
            body: Box::new(substitute_comptime_params(body, values, shadowed)?),
        }),
        Expr::Begin(exprs) => Ok(Expr::Begin(
            exprs
                .iter()
                .map(|inner| substitute_comptime_params(inner, values, shadowed))
                .collect::<Result<_, _>>()?,
        )),
        Expr::Set(name, value) => {
            if values.contains_key(name) && !shadowed.contains(name) {
                return Err(SpecializeError::at(
                    format!("cannot assign to comptime parameter '{}'", name),
                    expr.span(),
                ));
            }
            Ok(Expr::Set(
                name.clone(),
                Box::new(substitute_comptime_params(value, values, shadowed)?),
            ))
        }
        Expr::Ann { expr: inner, ty } => Ok(Expr::Ann {
            expr: Box::new(substitute_comptime_params(inner, values, shadowed)?),
            ty: ty.clone(),
        }),
        Expr::Cast { expr: inner, ty } => Ok(Expr::Cast {
            expr: Box::new(substitute_comptime_params(inner, values, shadowed)?),
            ty: ty.clone(),
        }),
        Expr::Match { scrutinee, arms } => Ok(Expr::Match {
            scrutinee: Box::new(substitute_comptime_params(scrutinee, values, shadowed)?),
            arms: arms
                .iter()
                .map(|(pat, body)| {
                    let mut arm_shadowed = shadowed.clone();
                    collect_pattern_bindings(pat, &mut arm_shadowed);
                    Ok((
                        pat.clone(),
                        substitute_comptime_params(body, values, &arm_shadowed)?,
                    ))
                })
                .collect::<Result<_, SpecializeError>>()?,
        }),
        Expr::Foreach {
            index,
            index_ty,
            start,
            end,
            body,
        } => {
            let mut body_shadowed = shadowed.clone();
            body_shadowed.insert(index.clone());
            Ok(Expr::Foreach {
                index: index.clone(),
                index_ty: index_ty.clone(),
                start: Box::new(substitute_comptime_params(start, values, shadowed)?),
                end: Box::new(substitute_comptime_params(end, values, shadowed)?),
                body: Box::new(substitute_comptime_params(body, values, &body_shadowed)?),
            })
        }
        Expr::SpmdReduce {
            op,
            index,
            index_ty,
            start,
            end,
            init,
            value,
        } => {
            let mut value_shadowed = shadowed.clone();
            value_shadowed.insert(index.clone());
            Ok(Expr::SpmdReduce {
                op: *op,
                index: index.clone(),
                index_ty: index_ty.clone(),
                start: Box::new(substitute_comptime_params(start, values, shadowed)?),
                end: Box::new(substitute_comptime_params(end, values, shadowed)?),
                init: Box::new(substitute_comptime_params(init, values, shadowed)?),
                value: Box::new(substitute_comptime_params(value, values, &value_shadowed)?),
            })
        }
        Expr::StructGet { expr: inner, field } => Ok(Expr::StructGet {
            expr: Box::new(substitute_comptime_params(inner, values, shadowed)?),
            field: field.clone(),
        }),
        Expr::WithRegion { region, body } => Ok(Expr::WithRegion {
            region: region.clone(),
            body: body
                .iter()
                .map(|inner| substitute_comptime_params(inner, values, shadowed))
                .collect::<Result<_, _>>()?,
        }),
    }
}

/// Substitute type-valued comptime parameters into the generated specialization
/// body. Type values are bound into exactly one selected type position — the
/// element type of a `make-array` form (`(make-array T n)`) — where a bare type
/// name `T` (`Type::Var("T")`) resolves to the compile-time type value. Any
/// other use of a type parameter is rejected with a focused diagnostic, keeping
/// the supported surface narrow until further positions are explicitly added:
///   * a type parameter named in any other type position (annotation, cast,
///     binding, lambda, loop index, etc.) is rejected, and
///   * observing a type parameter as a runtime value (a bare `Var(T)`
///     expression) is rejected before lowering.
///
/// When `type_subs` is empty this is an identity transform, so functions with
/// only scalar comptime parameters are untouched.
fn substitute_type_params(
    expr: &Expr,
    type_subs: &HashMap<String, Type>,
) -> Result<Expr, SpecializeError> {
    if type_subs.is_empty() {
        return Ok(expr.clone());
    }
    let go = |e: &Expr| substitute_type_params(e, type_subs);
    match expr {
        Expr::Spanned { expr: inner, span } => Ok(Expr::spanned(go(inner)?, *span)),
        // Observing a type parameter as a runtime value is rejected before
        // lowering: a type value has no runtime representation.
        Expr::Var(name) if type_subs.contains_key(name) => Err(SpecializeError::at(
            format!(
                "type-valued comptime parameter '{}' cannot be used as a runtime value; \
                 it is only consumable in the element type of a `make-array` form",
                name
            ),
            expr.span(),
        )),
        Expr::Var(_) | Expr::Literal(_) | Expr::TypeLiteral { .. } => Ok(expr.clone()),
        Expr::Binary { op, lhs, rhs } => Ok(Expr::Binary {
            op: *op,
            lhs: Box::new(go(lhs)?),
            rhs: Box::new(go(rhs)?),
        }),
        Expr::Unary { op, expr: inner } => Ok(Expr::Unary {
            op: *op,
            expr: Box::new(go(inner)?),
        }),
        Expr::Call { func, args } => Ok(Expr::Call {
            func: Box::new(go(func)?),
            args: args.iter().map(go).collect::<Result<_, _>>()?,
        }),
        Expr::Comptime { expr: inner } => Ok(Expr::Comptime {
            expr: Box::new(go(inner)?),
        }),
        Expr::If {
            cond,
            then_branch,
            else_branch,
        } => Ok(Expr::If {
            cond: Box::new(go(cond)?),
            then_branch: Box::new(go(then_branch)?),
            else_branch: Box::new(go(else_branch)?),
        }),
        Expr::Let { bindings, body } => Ok(Expr::Let {
            bindings: bindings
                .iter()
                .map(|(name, ty, value)| {
                    if let Some(ty) = ty {
                        reject_type_param_use(ty, type_subs, value.span(), "a let binding type")?;
                    }
                    Ok((name.clone(), ty.clone(), go(value)?))
                })
                .collect::<Result<_, SpecializeError>>()?,
            body: Box::new(go(body)?),
        }),
        Expr::Lambda { params, ret, body } => {
            for (_, ty) in params {
                reject_type_param_use(ty, type_subs, body.span(), "a lambda parameter type")?;
            }
            if let Some(ret) = ret {
                reject_type_param_use(ret, type_subs, body.span(), "a lambda return type")?;
            }
            Ok(Expr::Lambda {
                params: params.clone(),
                ret: ret.clone(),
                body: Box::new(go(body)?),
            })
        }
        Expr::Tuple(elems) => Ok(Expr::Tuple(elems.iter().map(go).collect::<Result<_, _>>()?)),
        Expr::TupleRef { expr: inner, index } => Ok(Expr::TupleRef {
            expr: Box::new(go(inner)?),
            index: *index,
        }),
        Expr::Array(elems) => Ok(Expr::Array(elems.iter().map(go).collect::<Result<_, _>>()?)),
        // The single selected consumer position: substitute type parameters into
        // the element type of `make-array`.
        Expr::MakeArray { elem_ty, len } => Ok(Expr::MakeArray {
            elem_ty: substitute_type_in_type(elem_ty, type_subs),
            len: Box::new(go(len)?),
        }),
        Expr::ArrayRef { expr: inner, index } => Ok(Expr::ArrayRef {
            expr: Box::new(go(inner)?),
            index: Box::new(go(index)?),
        }),
        Expr::ArraySet {
            expr: inner,
            index,
            value,
        } => Ok(Expr::ArraySet {
            expr: Box::new(go(inner)?),
            index: Box::new(go(index)?),
            value: Box::new(go(value)?),
        }),
        Expr::While { cond, body } => Ok(Expr::While {
            cond: Box::new(go(cond)?),
            body: Box::new(go(body)?),
        }),
        Expr::Begin(exprs) => Ok(Expr::Begin(exprs.iter().map(go).collect::<Result<_, _>>()?)),
        Expr::Set(name, value) => Ok(Expr::Set(name.clone(), Box::new(go(value)?))),
        Expr::Ann { expr: inner, ty } => {
            reject_type_param_use(ty, type_subs, inner.span(), "an `ann` target type")?;
            Ok(Expr::Ann {
                expr: Box::new(go(inner)?),
                ty: ty.clone(),
            })
        }
        Expr::Cast { expr: inner, ty } => {
            reject_type_param_use(ty, type_subs, inner.span(), "a `cast` target type")?;
            Ok(Expr::Cast {
                expr: Box::new(go(inner)?),
                ty: ty.clone(),
            })
        }
        Expr::Match { scrutinee, arms } => Ok(Expr::Match {
            scrutinee: Box::new(go(scrutinee)?),
            arms: arms
                .iter()
                .map(|(pat, body)| Ok((pat.clone(), go(body)?)))
                .collect::<Result<_, SpecializeError>>()?,
        }),
        Expr::Foreach {
            index,
            index_ty,
            start,
            end,
            body,
        } => {
            reject_type_param_use(index_ty, type_subs, body.span(), "a loop index type")?;
            Ok(Expr::Foreach {
                index: index.clone(),
                index_ty: index_ty.clone(),
                start: Box::new(go(start)?),
                end: Box::new(go(end)?),
                body: Box::new(go(body)?),
            })
        }
        Expr::SpmdReduce {
            op,
            index,
            index_ty,
            start,
            end,
            init,
            value,
        } => {
            reject_type_param_use(index_ty, type_subs, value.span(), "a loop index type")?;
            Ok(Expr::SpmdReduce {
                op: *op,
                index: index.clone(),
                index_ty: index_ty.clone(),
                start: Box::new(go(start)?),
                end: Box::new(go(end)?),
                init: Box::new(go(init)?),
                value: Box::new(go(value)?),
            })
        }
        Expr::StructGet { expr: inner, field } => Ok(Expr::StructGet {
            expr: Box::new(go(inner)?),
            field: field.clone(),
        }),
        Expr::WithRegion { region, body } => Ok(Expr::WithRegion {
            region: region.clone(),
            body: body.iter().map(go).collect::<Result<_, _>>()?,
        }),
    }
}

/// Replace every `Type::Var(name)` that names a bound type parameter with its
/// compile-time type value, recursing through compound types so a parameter
/// nested in `(Array T 4)`/`(Tuple T ...)`/`(-> T ...)` is substituted too.
fn substitute_type_in_type(ty: &Type, type_subs: &HashMap<String, Type>) -> Type {
    match ty {
        Type::Var(name) => match type_subs.get(name) {
            Some(resolved) => resolved.clone(),
            None => ty.clone(),
        },
        Type::Func(args, ret) => Type::Func(
            args.iter()
                .map(|a| substitute_type_in_type(a, type_subs))
                .collect(),
            Box::new(substitute_type_in_type(ret, type_subs)),
        ),
        Type::Tuple(elems) => Type::Tuple(
            elems
                .iter()
                .map(|e| substitute_type_in_type(e, type_subs))
                .collect(),
        ),
        Type::Array(elem, n) => Type::Array(Box::new(substitute_type_in_type(elem, type_subs)), *n),
        Type::DynArray(elem) => Type::DynArray(Box::new(substitute_type_in_type(elem, type_subs))),
        Type::Region(region, elem) => Type::Region(
            region.clone(),
            Box::new(substitute_type_in_type(elem, type_subs)),
        ),
        other => other.clone(),
    }
}

/// Whether a type mentions any bound type parameter at any depth.
fn type_mentions_type_param(ty: &Type, type_subs: &HashMap<String, Type>) -> bool {
    match ty {
        Type::Var(name) => type_subs.contains_key(name),
        Type::Func(args, ret) => {
            args.iter().any(|a| type_mentions_type_param(a, type_subs))
                || type_mentions_type_param(ret, type_subs)
        }
        Type::Tuple(elems) => elems.iter().any(|e| type_mentions_type_param(e, type_subs)),
        Type::Array(elem, _) | Type::DynArray(elem) | Type::Region(_, elem) => {
            type_mentions_type_param(elem, type_subs)
        }
        _ => false,
    }
}

/// Reject a type position that names a type-valued comptime parameter outside
/// the single selected consumer (array element type). The diagnostic identifies
/// the offending type and the unsupported position.
fn reject_type_param_use(
    ty: &Type,
    type_subs: &HashMap<String, Type>,
    span: Span,
    position: &str,
) -> Result<(), SpecializeError> {
    if type_mentions_type_param(ty, type_subs) {
        return Err(SpecializeError::at(
            format!(
                "type-valued comptime parameter used in {} ({}); the only supported type position \
                 is the element type of a `make-array` form",
                position, ty
            ),
            span,
        ));
    }
    Ok(())
}

fn collect_pattern_bindings(pat: &Pattern, out: &mut HashSet<String>) {
    match pat {
        Pattern::Var(name, _) | Pattern::Binding(name) => {
            out.insert(name.clone());
        }
        Pattern::Tuple(items) => {
            for item in items {
                collect_pattern_bindings(item, out);
            }
        }
        Pattern::Variant { args, .. } => {
            for arg in args {
                collect_pattern_bindings(arg, out);
            }
        }
        Pattern::Wildcard | Pattern::Literal(_) => {}
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::parser::parse;

    fn generated_names(program: &Program) -> Vec<String> {
        program
            .decls
            .iter()
            .filter_map(|decl| match decl {
                Decl::DefFn { name, .. } if name.starts_with("__tl_specialized_") => {
                    Some(name.clone())
                }
                _ => None,
            })
            .collect()
    }

    #[test]
    fn repeated_comptime_calls_reuse_one_generated_function() {
        let program = parse(
            "(define (scale [comptime n : i64] [x : i64]) : i64 (* n x))
             (define (main) : i64 (+ (scale 2 10) (scale 2 20)))",
        )
        .unwrap();
        let specialized = specialize_program(&program).unwrap();
        let names = generated_names(&specialized);
        assert_eq!(names.len(), 1, "{specialized:#?}");
        let main = specialized
            .decls
            .iter()
            .find(|decl| matches!(decl, Decl::DefFn { name, .. } if name == "main"))
            .unwrap();
        if let Decl::DefFn { body, .. } = main {
            let text = format!("{body:#?}");
            assert!(text.contains(&names[0]), "{text}");
            assert!(
                !text.contains("func: Var(\n                    \"scale\""),
                "{text}"
            );
        }
    }

    #[test]
    fn different_comptime_values_generate_distinct_functions() {
        let program = parse(
            "(define (scale [comptime n : i64] [x : i64]) : i64 (* n x))
             (define (main) : i64 (+ (scale 2 10) (scale 3 20)))",
        )
        .unwrap();
        let specialized = specialize_program(&program).unwrap();
        assert_eq!(generated_names(&specialized).len(), 2);
    }

    #[test]
    fn comptime_value_key_fragments_are_stable() {
        assert_eq!(CtfeValue::I64(-7).key_fragment(), "i64:-7");
        assert_eq!(CtfeValue::F64(-0.0).key_fragment(), "f64:8000000000000000");
        assert_eq!(CtfeValue::Bool(true).key_fragment(), "bool:1");
        assert_eq!(CtfeValue::Bool(false).key_fragment(), "bool:0");
        assert_eq!(CtfeValue::Char('A').key_fragment(), "char:41");
        assert_eq!(CtfeValue::Unit.key_fragment(), "unit");
        assert_eq!(
            CtfeValue::Type(Type::Array(Box::new(Type::I64), 4)).key_fragment(),
            "type:(Array i64 4)"
        );
    }

    #[test]
    fn generated_names_are_deterministic_across_runs() {
        let src = "
            (define (mix [comptime n : i64] [comptime flag : bool] [x : i64]) : i64
              (if flag (+ n x) x))
            (define (main) : i64 (mix 5 true 10))
        ";
        let first = generated_names(&specialize_program(&parse(src).unwrap()).unwrap());
        let second = generated_names(&specialize_program(&parse(src).unwrap()).unwrap());
        assert_eq!(first, second);
        assert_eq!(first.len(), 1);
    }

    #[test]
    fn local_binding_can_shadow_comptime_function_name() {
        let program = parse(
            "(define (scale [comptime n : i64] [x : i64]) : i64 (* n x))
             (define (main) : i64 (let ([scale : i64 7]) scale))",
        )
        .unwrap();
        let specialized = specialize_program(&program).unwrap();
        assert!(generated_names(&specialized).is_empty());
    }

    #[test]
    fn substitution_respects_sequential_let_shadowing() {
        let program = parse(
            "(define (pick [comptime n : i64]) : i64
               (let ([n : i64 1] [m : i64 n]) m))
             (define (main) : i64 (pick 42))",
        )
        .unwrap();
        let specialized = specialize_program(&program).unwrap();
        let generated = specialized
            .decls
            .iter()
            .find(|decl| matches!(decl, Decl::DefFn { name, .. } if name.starts_with("__tl_specialized_")))
            .expect("generated specialization");
        let Decl::DefFn { body, .. } = generated else {
            panic!("expected generated function, got {generated:?}");
        };
        let Expr::Let { bindings, .. } = body.unspan() else {
            panic!("expected let body, got {body:?}");
        };
        assert!(matches!(
            bindings[0].2.unspan(),
            Expr::Literal(crate::ast::Literal::Int(1))
        ));
        assert!(matches!(bindings[1].2.unspan(), Expr::Var(name) if name == "n"));
    }

    #[test]
    fn runtime_comptime_argument_is_rejected() {
        let program = parse(
            "(define (scale [comptime n : i64] [x : i64]) : i64 (* n x))
             (define (main [n : i64]) : i64 (scale n 10))",
        )
        .unwrap();
        let err = specialize_program(&program).unwrap_err();
        assert!(
            err.msg.contains("not compile-time-known"),
            "got: {}",
            err.msg
        );
    }

    // ------------------------------------------------------------------
    // Type-valued comptime parameters — Issue #742
    // ------------------------------------------------------------------

    /// The element type of the (single) `make-array` form in the generated body.
    fn generated_make_array_elem(program: &Program) -> Type {
        let generated = program
            .decls
            .iter()
            .find(|decl| matches!(decl, Decl::DefFn { name, .. } if name.starts_with("__tl_specialized_")))
            .expect("generated specialization");
        let Decl::DefFn { body, .. } = generated else {
            panic!("expected generated function");
        };
        find_make_array_elem(body).expect("make-array in generated body")
    }

    fn find_make_array_elem(expr: &Expr) -> Option<Type> {
        match expr.unspan() {
            Expr::MakeArray { elem_ty, .. } => Some(elem_ty.clone()),
            Expr::Begin(exprs) => exprs.iter().find_map(find_make_array_elem),
            Expr::Let { body, .. } => find_make_array_elem(body),
            _ => None,
        }
    }

    #[test]
    fn type_valued_param_substitutes_into_make_array_elem_type() {
        let program = parse(
            "(define (alloc [comptime T : type] [n : i64]) : (Array i64)
               (make-array T n))
             (define (main) : (Array i64) (alloc (type i64) 4))",
        )
        .unwrap();
        let specialized = specialize_program(&program).unwrap();
        assert_eq!(generated_make_array_elem(&specialized), Type::I64);
    }

    #[test]
    fn type_valued_param_repeated_identical_calls_reuse_one_function() {
        let program = parse(
            "(define (alloc [comptime T : type] [n : i64]) : (Array i64)
               (make-array T n))
             (define (main) : i64
               (begin (alloc (type i64) 4) (alloc (type i64) 8) 0))",
        )
        .unwrap();
        let specialized = specialize_program(&program).unwrap();
        assert_eq!(generated_names(&specialized).len(), 1);
    }

    #[test]
    fn type_valued_param_distinct_shapes_generate_distinct_functions() {
        let program = parse(
            "(define (alloc [comptime T : type] [n : i64]) : (Array i64)
               (make-array T n))
             (define (main) : i64
               (begin (alloc (type i64) 4) (alloc (type f64) 4) 0))",
        )
        .unwrap();
        let specialized = specialize_program(&program).unwrap();
        assert_eq!(generated_names(&specialized).len(), 2);
    }

    #[test]
    fn type_valued_param_key_fragment_distinguishes_runtime_shape() {
        // i32 and i64 differ in runtime shape, so the cache keys differ.
        let i32_key = specialization_key("alloc", &[CtfeValue::Type(Type::I32), CtfeValue::I64(4)]);
        let i64_key = specialization_key("alloc", &[CtfeValue::Type(Type::I64), CtfeValue::I64(4)]);
        assert_ne!(i32_key, i64_key);
        assert!(i64_key.contains("type:i64"), "{i64_key}");
    }

    #[test]
    fn type_valued_param_generated_names_are_deterministic() {
        let src = "(define (alloc [comptime T : type] [n : i64]) : (Array i64)
                     (make-array T n))
                   (define (main) : (Array i64) (alloc (type i64) 4))";
        let first = generated_names(&specialize_program(&parse(src).unwrap()).unwrap());
        let second = generated_names(&specialize_program(&parse(src).unwrap()).unwrap());
        assert_eq!(first, second);
        assert_eq!(first.len(), 1);
    }

    #[test]
    fn type_valued_param_rejects_runtime_observation() {
        let program = parse(
            "(define (bad [comptime T : type] [n : i64]) : i64 T)
             (define (main) : i64 (bad (type i64) 4))",
        )
        .unwrap();
        let err = specialize_program(&program).unwrap_err();
        assert!(
            err.msg.contains("cannot be used as a runtime value"),
            "got: {}",
            err.msg
        );
    }

    #[test]
    fn type_valued_param_rejects_unselected_type_position() {
        let program = parse(
            "(define (bad [comptime T : type] [x : i64]) : i64 (ann x : T))
             (define (main) : i64 (bad (type i64) 4))",
        )
        .unwrap();
        let err = specialize_program(&program).unwrap_err();
        assert!(
            err.msg.contains("only supported type position")
                && err.msg.contains("`ann` target type"),
            "got: {}",
            err.msg
        );
    }

    #[test]
    fn type_valued_param_rejects_scalar_argument() {
        let program = parse(
            "(define (alloc [comptime T : type] [n : i64]) : (Array i64)
               (make-array T n))
             (define (main) : (Array i64) (alloc 4 4))",
        )
        .unwrap();
        let err = specialize_program(&program).unwrap_err();
        assert!(err.msg.contains("must be a type value"), "got: {}", err.msg);
    }

    #[test]
    fn scalar_param_rejects_type_argument() {
        let program = parse(
            "(define (scale [comptime n : i64] [x : i64]) : i64 (* n x))
             (define (main) : i64 (scale (type i64) 10))",
        )
        .unwrap();
        let err = specialize_program(&program).unwrap_err();
        assert!(
            err.msg.contains("has type type, expected i64"),
            "got: {}",
            err.msg
        );
    }

    #[test]
    fn type_valued_param_omitted_from_runtime_signature() {
        let program = parse(
            "(define (alloc [comptime T : type] [n : i64]) : (Array i64)
               (make-array T n))
             (define (main) : (Array i64) (alloc (type i64) 4))",
        )
        .unwrap();
        let specialized = specialize_program(&program).unwrap();
        let generated = specialized
            .decls
            .iter()
            .find(|decl| matches!(decl, Decl::DefFn { name, .. } if name.starts_with("__tl_specialized_")))
            .unwrap();
        let Decl::DefFn { params, .. } = generated else {
            panic!("expected generated function");
        };
        assert_eq!(params.len(), 1, "comptime type param must be removed");
        assert_eq!(params[0].0, "n");
    }

    #[test]
    fn type_valued_param_nested_in_compound_type_is_substituted() {
        let program = parse(
            "(define (alloc [comptime T : type] [n : i64]) : (Array (Array i64 2))
               (make-array (Array T 2) n))
             (define (main) : (Array (Array i64 2)) (alloc (type i64) 4))",
        )
        .unwrap();
        let specialized = specialize_program(&program).unwrap();
        assert_eq!(
            generated_make_array_elem(&specialized),
            Type::Array(Box::new(Type::I64), 2)
        );
    }
}
