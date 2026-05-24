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
            Expr::Var(_) | Expr::Literal(_) => Ok(expr.clone()),
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
                if value.ty() != *param_ty {
                    return Err(SpecializeError::at(
                        format!(
                            "comptime argument '{}' for function '{}' has type {}, expected {}",
                            param_name,
                            name,
                            value.ty(),
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
                substitutions.insert(param_name.clone(), value.clone());
                value_idx += 1;
            } else {
                runtime_params.push((param_name.clone(), param_ty.clone()));
            }
        }

        let substituted =
            substitute_comptime_params(&template.body, &substitutions, &HashSet::new())?;
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
                    "unsupported comptime parameter type {}; supported scalar types are i64, f64, bool, char, and unit",
                    ty
                ),
                span,
            ));
        }
    }
    Ok(())
}

fn is_supported_comptime_param_type(ty: &Type) -> bool {
    matches!(
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

fn literal_expr(value: &CtfeValue, span: Span) -> Expr {
    Expr::spanned(Expr::Literal(value.to_literal()), span)
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
                Ok(literal_expr(value, expr.span()))
            } else {
                Ok(expr.clone())
            }
        }
        Expr::Var(_) | Expr::Literal(_) => Ok(expr.clone()),
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
}
