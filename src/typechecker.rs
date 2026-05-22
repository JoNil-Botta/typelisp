use crate::ast::*;
use crate::diagnostic::Diagnostic;
use crate::span::Span;
use crate::types::Type;
use std::collections::HashMap;
use std::fmt;

#[derive(Debug, Clone)]
pub struct TypeError {
    pub msg: String,
    pub span: Span,
}

impl TypeError {
    fn at(msg: impl Into<String>, span: Span) -> Self {
        TypeError {
            msg: msg.into(),
            span,
        }
    }

    pub fn to_diagnostic(&self) -> Diagnostic {
        Diagnostic::error(self.msg.clone(), self.span).with_code("E0200")
    }
}

impl fmt::Display for TypeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "type error: {}", self.msg)
    }
}

pub struct TypeChecker {
    env: Vec<HashMap<String, Type>>,
    func_ret: Option<Type>,
    enums: EnumRegistry,
}

impl TypeChecker {
    pub fn new() -> Self {
        let mut globals = HashMap::new();
        // Built-in externals
        globals.insert(
            "print".into(),
            Type::Func(vec![Type::I64], Box::new(Type::Unit)),
        );
        globals.insert(
            "print-bool".into(),
            Type::Func(vec![Type::Bool], Box::new(Type::Unit)),
        );
        globals.insert(
            "print-float".into(),
            Type::Func(vec![Type::F64], Box::new(Type::Unit)),
        );
        TypeChecker {
            env: vec![globals],
            func_ret: None,
            enums: EnumRegistry::default(),
        }
    }

    fn lookup(&self, name: &str) -> Option<Type> {
        for scope in self.env.iter().rev() {
            if let Some(ty) = scope.get(name) {
                return Some(ty.clone());
            }
        }
        None
    }

    fn bind(&mut self, name: String, ty: Type) {
        self.env.last_mut().unwrap().insert(name, ty);
    }

    fn push_scope(&mut self) {
        self.env.push(HashMap::new());
    }

    fn pop_scope(&mut self) {
        self.env.pop();
    }

    pub fn check_program(&mut self, prog: &Program) -> Result<(), TypeError> {
        // Build the enum registry up front so declared types and constructors
        // can be resolved/registered in the first pass.
        self.enums = EnumRegistry::from_program(prog);

        // Recursive enums (a variant whose payload references the enum itself,
        // directly or via a compound type) require heap indirection and are out
        // of scope for this slice (deferred to #13). Reject them with a clear
        // diagnostic rather than miscompiling.
        for decl in &prog.decls {
            if let Decl::DefEnum { name, variants } = decl {
                for v in variants {
                    for f in &v.fields {
                        if type_mentions_enum(&self.enums.resolve_type(f), name) {
                            return Err(TypeError::at(
                                format!(
                                    "recursive enum '{}' (variant '{}') is not yet supported \
                                     (needs heap indirection, see #13)",
                                    name, v.name
                                ),
                                Span::default(),
                            ));
                        }
                    }
                }
            }
        }

        // Register enum constructors as callable functions: a variant with
        // fields `(-> field... EnumName)`, a nullary variant just `EnumName`.
        // This makes constructor calls type-check through the ordinary call
        // path (arity + per-argument checks come for free).
        for decl in &prog.decls {
            if let Decl::DefEnum { name, variants } = decl {
                for v in variants {
                    let fields: Vec<Type> = v
                        .fields
                        .iter()
                        .map(|t| self.enums.resolve_type(t))
                        .collect();
                    let ctor_ty = if fields.is_empty() {
                        Type::Enum(name.clone())
                    } else {
                        Type::Func(fields, Box::new(Type::Enum(name.clone())))
                    };
                    self.bind(v.name.clone(), ctor_ty);
                }
            }
        }

        // First pass: collect all declarations
        for decl in &prog.decls {
            match decl {
                Decl::Def { name, ty, value } => {
                    let inferred = if let Some(ty) = ty {
                        let ty = self.enums.resolve_type(ty);
                        let val_ty = self.check_expr(value)?;
                        if !self.types_equal(&ty, &val_ty) {
                            return Err(TypeError::at(
                                format!(
                                    "type mismatch in definition of '{}': expected {}, got {}",
                                    name, ty, val_ty
                                ),
                                value.span(),
                            ));
                        }
                        ty
                    } else {
                        self.check_expr(value)?
                    };
                    self.bind(name.clone(), inferred);
                }
                Decl::DefFn {
                    name,
                    params,
                    ret,
                    body: _,
                } => {
                    let func_ty = Type::Func(
                        params
                            .iter()
                            .map(|(_, t)| self.enums.resolve_type(t))
                            .collect(),
                        Box::new(self.enums.resolve_type(ret)),
                    );
                    self.bind(name.clone(), func_ty);
                }
                Decl::Extern { name, ty } => {
                    self.bind(name.clone(), self.enums.resolve_type(ty));
                }
                Decl::DefEnum { .. } => {}
            }
        }

        // Second pass: check function bodies
        for decl in &prog.decls {
            if let Decl::DefFn {
                name,
                params,
                ret,
                body,
            } = decl
            {
                self.push_scope();
                for (param, ty) in params {
                    self.bind(param.clone(), self.enums.resolve_type(ty));
                }
                let ret = self.enums.resolve_type(ret);
                let old_ret = self.func_ret.clone();
                self.func_ret = Some(ret.clone());
                let body_ty = self.check_expr(body)?;
                self.func_ret = old_ret;
                self.pop_scope();

                if !self.types_equal(&ret, &body_ty) {
                    return Err(TypeError::at(
                        format!(
                            "function '{}' return type mismatch: expected {}, got {}",
                            name, ret, body_ty
                        ),
                        body.span(),
                    ));
                }
            }
        }

        Ok(())
    }

    fn check_expr(&mut self, expr: &Expr) -> Result<Type, TypeError> {
        let span = expr.span();
        match expr.unspan() {
            Expr::Literal(lit) => match lit {
                Literal::Int(_) => Ok(Type::I64), // Default to i64
                Literal::Float(_) => Ok(Type::F64),
                Literal::Bool(_) => Ok(Type::Bool),
                Literal::Char(_) => Ok(Type::Char),
                Literal::String(_) => Ok(Type::Var("String".into())), // Not fully supported yet
                Literal::Unit => Ok(Type::Unit),
            },
            Expr::Var(name) => self
                .lookup(name)
                .ok_or_else(|| TypeError::at(format!("unbound variable: {}", name), span)),
            Expr::Binary { op, lhs, rhs } => {
                let lhs_ty = self.check_expr(lhs)?;
                let rhs_ty = self.check_expr(rhs)?;

                match op {
                    BinOp::Add | BinOp::Sub | BinOp::Mul | BinOp::Div | BinOp::Mod => {
                        if !lhs_ty.is_numeric() || !rhs_ty.is_numeric() {
                            return Err(TypeError::at(
                                format!(
                                    "arithmetic operator requires numeric types, got {} and {}",
                                    lhs_ty, rhs_ty
                                ),
                                span,
                            ));
                        }
                        if !self.types_equal(&lhs_ty, &rhs_ty) {
                            return Err(TypeError::at(
                                format!("type mismatch in arithmetic: {} and {}", lhs_ty, rhs_ty),
                                span,
                            ));
                        }
                        Ok(lhs_ty)
                    }
                    BinOp::Eq | BinOp::Ne | BinOp::Lt | BinOp::Le | BinOp::Gt | BinOp::Ge => {
                        if !self.types_equal(&lhs_ty, &rhs_ty) {
                            return Err(TypeError::at(
                                format!("comparison type mismatch: {} and {}", lhs_ty, rhs_ty),
                                span,
                            ));
                        }
                        Ok(Type::Bool)
                    }
                    BinOp::And | BinOp::Or => {
                        if lhs_ty != Type::Bool || rhs_ty != Type::Bool {
                            return Err(TypeError::at(
                                format!(
                                    "logical operator requires bool, got {} and {}",
                                    lhs_ty, rhs_ty
                                ),
                                span,
                            ));
                        }
                        Ok(Type::Bool)
                    }
                    BinOp::BitAnd | BinOp::BitOr | BinOp::BitXor | BinOp::Shl | BinOp::Shr => {
                        if !lhs_ty.is_integer() || !rhs_ty.is_integer() {
                            return Err(TypeError::at(
                                format!(
                                    "bitwise operator requires integer types, got {} and {}",
                                    lhs_ty, rhs_ty
                                ),
                                span,
                            ));
                        }
                        Ok(lhs_ty)
                    }
                }
            }
            Expr::Unary { op, expr } => {
                let ty = self.check_expr(expr)?;
                match op {
                    UnOp::Neg => {
                        if !ty.is_numeric() {
                            return Err(TypeError::at(
                                format!("negation requires numeric type, got {}", ty),
                                span,
                            ));
                        }
                        Ok(ty)
                    }
                    UnOp::Not => {
                        if ty != Type::Bool {
                            return Err(TypeError::at(
                                format!("not requires bool, got {}", ty),
                                span,
                            ));
                        }
                        Ok(Type::Bool)
                    }
                    UnOp::BitNot => {
                        if !ty.is_integer() {
                            return Err(TypeError::at(
                                format!("bit-not requires integer, got {}", ty),
                                span,
                            ));
                        }
                        Ok(ty)
                    }
                }
            }
            Expr::Call { func, args } => {
                let func_ty = self.check_expr(func)?;
                match func_ty {
                    Type::Func(param_tys, ret_ty) => {
                        if param_tys.len() != args.len() {
                            return Err(TypeError::at(
                                format!(
                                    "function expects {} arguments, got {}",
                                    param_tys.len(),
                                    args.len()
                                ),
                                span,
                            ));
                        }
                        for (expected, arg) in param_tys.iter().zip(args.iter()) {
                            let arg_ty = self.check_expr(arg)?;
                            if !self.types_equal(expected, &arg_ty) {
                                return Err(TypeError::at(
                                    format!(
                                        "argument type mismatch: expected {}, got {}",
                                        expected, arg_ty
                                    ),
                                    arg.span(),
                                ));
                            }
                        }
                        Ok(*ret_ty)
                    }
                    _ => Err(TypeError::at(
                        format!("expected function type, got {}", func_ty),
                        func.span(),
                    )),
                }
            }
            Expr::If {
                cond,
                then_branch,
                else_branch,
            } => {
                let cond_ty = self.check_expr(cond)?;
                if cond_ty != Type::Bool {
                    return Err(TypeError::at(
                        format!("if condition must be bool, got {}", cond_ty),
                        cond.span(),
                    ));
                }
                let then_ty = self.check_expr(then_branch)?;
                let else_ty = self.check_expr(else_branch)?;
                if !self.types_equal(&then_ty, &else_ty) {
                    return Err(TypeError::at(
                        format!(
                            "if branches have different types: {} and {}",
                            then_ty, else_ty
                        ),
                        span,
                    ));
                }
                Ok(then_ty)
            }
            Expr::Let { bindings, body } => {
                self.push_scope();
                for (name, ty, value) in bindings {
                    let val_ty = self.check_expr(value)?;
                    let ty = ty.as_ref().map(|t| self.enums.resolve_type(t));
                    let binding_ty = if let Some(expected) = &ty {
                        if !self.types_equal(expected, &val_ty) {
                            return Err(TypeError::at(
                                format!(
                                    "let binding '{}' type mismatch: expected {}, got {}",
                                    name, expected, val_ty
                                ),
                                value.span(),
                            ));
                        }
                        expected.clone()
                    } else {
                        val_ty
                    };
                    self.bind(name.clone(), binding_ty);
                }
                let body_ty = self.check_expr(body)?;
                self.pop_scope();
                Ok(body_ty)
            }
            Expr::Lambda { params, ret, body } => {
                self.push_scope();
                for (param, ty) in params {
                    self.bind(param.clone(), ty.clone());
                }
                let old_ret = self.func_ret.clone();
                self.func_ret = ret.clone();
                let body_ty = self.check_expr(body)?;
                self.func_ret = old_ret;
                self.pop_scope();

                let ret_ty = ret.clone().unwrap_or(body_ty.clone());
                if !self.types_equal(&ret_ty, &body_ty) {
                    return Err(TypeError::at(
                        format!(
                            "lambda return type mismatch: expected {}, got {}",
                            ret_ty, body_ty
                        ),
                        body.span(),
                    ));
                }

                Ok(Type::Func(
                    params.iter().map(|(_, t)| t.clone()).collect(),
                    Box::new(ret_ty),
                ))
            }
            Expr::Tuple(elems) => {
                let mut types = Vec::new();
                for e in elems {
                    types.push(self.check_expr(e)?);
                }
                Ok(Type::Tuple(types))
            }
            Expr::TupleRef { expr, index } => {
                let ty = self.check_expr(expr)?;
                match ty {
                    Type::Tuple(elems) => {
                        if *index >= elems.len() {
                            return Err(TypeError::at(
                                format!(
                                    "tuple index {} out of bounds (len {})",
                                    index,
                                    elems.len()
                                ),
                                span,
                            ));
                        }
                        Ok(elems[*index].clone())
                    }
                    _ => Err(TypeError::at(
                        format!("tuple-ref requires tuple type, got {}", ty),
                        expr.span(),
                    )),
                }
            }
            Expr::Array(elems) => {
                if elems.is_empty() {
                    return Err(TypeError::at("cannot infer type of empty array", span));
                }
                let first_ty = self.check_expr(&elems[0])?;
                for e in &elems[1..] {
                    let ty = self.check_expr(e)?;
                    if !self.types_equal(&first_ty, &ty) {
                        return Err(TypeError::at(
                            "array elements must have same type",
                            e.span(),
                        ));
                    }
                }
                Ok(Type::Array(Box::new(first_ty), elems.len()))
            }
            Expr::ArrayRef { expr, index } => {
                let arr_ty = self.check_expr(expr)?;
                let idx_ty = self.check_expr(index)?;
                if !idx_ty.is_integer() {
                    return Err(TypeError::at(
                        format!("array index must be integer, got {}", idx_ty),
                        index.span(),
                    ));
                }
                match arr_ty {
                    Type::Array(elem_ty, _) => Ok(*elem_ty),
                    _ => Err(TypeError::at(
                        format!("array-ref requires array type, got {}", arr_ty),
                        expr.span(),
                    )),
                }
            }
            Expr::While { cond, body } => {
                let cond_ty = self.check_expr(cond)?;
                if cond_ty != Type::Bool {
                    return Err(TypeError::at(
                        format!("while condition must be bool, got {}", cond_ty),
                        cond.span(),
                    ));
                }
                self.check_expr(body)?;
                Ok(Type::Unit)
            }
            Expr::Begin(exprs) => {
                let mut last_ty = Type::Unit;
                for e in exprs {
                    last_ty = self.check_expr(e)?;
                }
                Ok(last_ty)
            }
            Expr::Set(name, expr) => {
                let val_ty = self.check_expr(expr)?;
                let var_ty = self.lookup(name).ok_or_else(|| {
                    TypeError::at(format!("unbound variable in set!: {}", name), span)
                })?;
                if !self.types_equal(&var_ty, &val_ty) {
                    return Err(TypeError::at(
                        format!(
                            "set! type mismatch: variable {} has type {}, got {}",
                            name, var_ty, val_ty
                        ),
                        expr.span(),
                    ));
                }
                Ok(Type::Unit)
            }
            Expr::Ann { expr, ty } => {
                let ty = self.enums.resolve_type(ty);
                let expr_ty = self.check_expr(expr)?;
                if !self.types_equal(&ty, &expr_ty) {
                    return Err(TypeError::at(
                        format!("type annotation mismatch: expected {}, got {}", ty, expr_ty),
                        span,
                    ));
                }
                Ok(ty)
            }
            Expr::Match { scrutinee, arms } => self.check_match(scrutinee, arms, span),
            Expr::Cast { expr, ty } => {
                let ty = self.enums.resolve_type(ty);
                let expr_ty = self.check_expr(expr)?;
                // Casts are only defined between scalar number-like types
                // (integers and `char`, which is an 8-bit code unit here).
                let castable = |t: &Type| t.is_integer() || matches!(t, Type::Char);
                if !castable(&expr_ty) || !castable(&ty) {
                    return Err(TypeError::at(
                        format!(
                            "cast requires integer/char source and target, got {} -> {}",
                            expr_ty, ty
                        ),
                        span,
                    ));
                }
                Ok(ty)
            }
            Expr::Spanned { expr, .. } => self.check_expr(expr),
        }
    }

    fn check_match(
        &mut self,
        scrutinee: &Expr,
        arms: &[(Pattern, Expr)],
        span: Span,
    ) -> Result<Type, TypeError> {
        let scrut_ty = self.check_expr(scrutinee)?;
        let enum_name = match &scrut_ty {
            Type::Enum(n) => n.clone(),
            other => {
                return Err(TypeError::at(
                    format!("match scrutinee must be an enum type, got {}", other),
                    scrutinee.span(),
                ));
            }
        };
        if arms.is_empty() {
            return Err(TypeError::at("match must have at least one arm", span));
        }

        let variant_count = self
            .enums
            .variants(&enum_name)
            .map(|v| v.len())
            .unwrap_or(0);

        let mut result_ty: Option<Type> = None;
        let mut covered: Vec<bool> = vec![false; variant_count];
        let mut has_wildcard = false;

        for (pat, body) in arms {
            self.push_scope();
            match pat {
                Pattern::Wildcard => {
                    has_wildcard = true;
                }
                Pattern::Variant { name, bindings } => {
                    let (owner, tag, fields) =
                        self.enums.lookup_variant(name).ok_or_else(|| {
                            TypeError::at(
                                format!("unknown variant '{}' in match", name),
                                body.span(),
                            )
                        })?;
                    if owner != enum_name {
                        let owner = owner.to_string();
                        self.pop_scope();
                        return Err(TypeError::at(
                            format!(
                                "variant '{}' belongs to enum {}, not {}",
                                name, owner, enum_name
                            ),
                            body.span(),
                        ));
                    }
                    if bindings.len() != fields.len() {
                        let nfields = fields.len();
                        self.pop_scope();
                        return Err(TypeError::at(
                            format!(
                                "variant '{}' binds {} fields but pattern has {}",
                                name,
                                nfields,
                                bindings.len()
                            ),
                            body.span(),
                        ));
                    }
                    let field_tys: Vec<Type> = fields.to_vec();
                    for (b, fty) in bindings.iter().zip(field_tys.iter()) {
                        self.bind(b.clone(), fty.clone());
                    }
                    covered[tag] = true;
                }
                // Var/Tuple patterns are not supported in `match` arms yet.
                other => {
                    self.pop_scope();
                    return Err(TypeError::at(
                        format!("unsupported match pattern: {:?}", other),
                        body.span(),
                    ));
                }
            }
            let body_ty = self.check_expr(body)?;
            self.pop_scope();

            match &result_ty {
                None => result_ty = Some(body_ty),
                Some(expected) => {
                    if !self.types_equal(expected, &body_ty) {
                        return Err(TypeError::at(
                            format!(
                                "match arms have different types: {} and {}",
                                expected, body_ty
                            ),
                            body.span(),
                        ));
                    }
                }
            }
        }

        // Exhaustiveness: every variant must be covered, or a wildcard present.
        if !has_wildcard {
            let missing: Vec<String> = self
                .enums
                .variants(&enum_name)
                .map(|vs| {
                    vs.iter()
                        .enumerate()
                        .filter(|(i, _)| !covered[*i])
                        .map(|(_, v)| v.name.clone())
                        .collect()
                })
                .unwrap_or_default();
            if !missing.is_empty() {
                return Err(TypeError::at(
                    format!(
                        "non-exhaustive match on {}: missing variant(s) {}",
                        enum_name,
                        missing.join(", ")
                    ),
                    span,
                ));
            }
        }

        Ok(result_ty.unwrap_or(Type::Unit))
    }

    fn types_equal(&self, a: &Type, b: &Type) -> bool {
        match (a, b) {
            (Type::Var(_), _) | (_, Type::Var(_)) => true, // Type variables unify with anything
            (Type::Func(a_args, a_ret), Type::Func(b_args, b_ret)) => {
                a_args.len() == b_args.len()
                    && a_args
                        .iter()
                        .zip(b_args.iter())
                        .all(|(a, b)| self.types_equal(a, b))
                    && self.types_equal(a_ret, b_ret)
            }
            (Type::Tuple(a), Type::Tuple(b)) => {
                a.len() == b.len() && a.iter().zip(b.iter()).all(|(a, b)| self.types_equal(a, b))
            }
            (Type::Array(a, an), Type::Array(b, bn)) => an == bn && self.types_equal(a, b),
            _ => a == b,
        }
    }
}

/// Whether `ty` (after enum resolution) refers to the enum named `name`,
/// directly or nested inside a compound type. Used to reject recursive enums.
fn type_mentions_enum(ty: &Type, name: &str) -> bool {
    match ty {
        Type::Enum(n) => n == name,
        Type::Func(args, ret) => {
            args.iter().any(|a| type_mentions_enum(a, name)) || type_mentions_enum(ret, name)
        }
        Type::Tuple(elems) => elems.iter().any(|e| type_mentions_enum(e, name)),
        Type::Array(elem, _) => type_mentions_enum(elem, name),
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::parser::parse;

    #[test]
    fn test_typecheck_basic() {
        let prog = parse("(define x : i64 42)").unwrap();
        let mut tc = TypeChecker::new();
        assert!(tc.check_program(&prog).is_ok());
    }

    #[test]
    fn test_typecheck_function() {
        let prog = parse(
            r#"
            (define (add [a : i64] [b : i64]) : i64 (+ a b))
        "#,
        )
        .unwrap();
        let mut tc = TypeChecker::new();
        assert!(tc.check_program(&prog).is_ok());
    }

    #[test]
    fn test_typecheck_error() {
        let prog = parse(
            r#"
            (define (bad [a : i64] [b : bool]) : i64 (+ a b))
        "#,
        )
        .unwrap();
        let mut tc = TypeChecker::new();
        assert!(tc.check_program(&prog).is_err());
    }

    #[test]
    fn test_typecheck_error_carries_span() {
        let src = "(define (bad [a : i64] [b : bool]) : i64 (+ a b))";
        let prog = parse(src).unwrap();
        let mut tc = TypeChecker::new();
        let err = tc.check_program(&prog).unwrap_err();
        assert_eq!(err.span, Span::new(1, 42, 1, 49), "error: {}", err);
    }

    #[test]
    fn test_typecheck_error_diagnostic_renders_caret() {
        use crate::diagnostic::format_diagnostic;

        let src = "(define (bad [a : i64] [b : bool]) : i64 (+ a b))";
        let prog = parse(src).unwrap();
        let mut tc = TypeChecker::new();
        let err = tc.check_program(&prog).unwrap_err();
        let rendered = format_diagnostic(&err.to_diagnostic(), src, "test.tl");

        assert!(rendered.contains("error[E0200]"), "got:\n{}", rendered);
        assert!(rendered.contains("--> test.tl:1:42"), "got:\n{}", rendered);
        assert!(
            rendered.contains(" 1 | (define (bad [a : i64] [b : bool]) : i64 (+ a b))"),
            "got:\n{}",
            rendered
        );
        assert!(rendered.contains("^^^^^^^"), "got:\n{}", rendered);
    }

    // ------------------------------------------------------------------
    // Sum types + pattern matching — Issue #41
    // ------------------------------------------------------------------

    fn check(src: &str) -> Result<(), TypeError> {
        let prog = parse(src).unwrap();
        let mut tc = TypeChecker::new();
        tc.check_program(&prog)
    }

    const SHAPE: &str = "(defenum Shape (Circle i64) (Square i64) (Nothing))";

    #[test]
    fn test_typecheck_match_well_typed() {
        let src = format!(
            "{SHAPE}\n(define (area [s : Shape]) : i64 \
               (match s [(Circle r) (* r r)] [(Square w) (* w w)] [Nothing 0]))"
        );
        assert!(check(&src).is_ok());
    }

    #[test]
    fn test_typecheck_match_wildcard_is_exhaustive() {
        let src = format!(
            "{SHAPE}\n(define (area [s : Shape]) : i64 \
               (match s [(Circle r) r] [_ 0]))"
        );
        assert!(check(&src).is_ok());
    }

    #[test]
    fn test_typecheck_nullary_constructor() {
        let src = format!("{SHAPE}\n(define (n) : Shape Nothing)");
        assert!(check(&src).is_ok());
    }

    #[test]
    fn test_typecheck_constructor_arity_checked() {
        // Circle takes one i64; calling with none is an arity error via the
        // ordinary call path.
        let src = format!("{SHAPE}\n(define (c) : Shape (Circle))");
        assert!(check(&src).is_err());
    }

    #[test]
    fn test_typecheck_constructor_arg_type_checked() {
        let src = format!("{SHAPE}\n(define (c) : Shape (Circle true))");
        assert!(check(&src).is_err());
    }

    #[test]
    fn test_typecheck_match_unknown_variant_is_err() {
        let src = format!(
            "{SHAPE}\n(define (area [s : Shape]) : i64 \
               (match s [(Circle r) r] [(Triangle x) x] [Nothing 0]))"
        );
        let err = check(&src).unwrap_err();
        assert!(err.msg.contains("unknown variant"), "got: {}", err.msg);
    }

    #[test]
    fn test_typecheck_match_arm_type_mismatch_is_err() {
        let src = format!(
            "{SHAPE}\n(define (area [s : Shape]) : i64 \
               (match s [(Circle r) r] [(Square w) true] [Nothing 0]))"
        );
        let err = check(&src).unwrap_err();
        assert!(err.msg.contains("different types"), "got: {}", err.msg);
    }

    #[test]
    fn test_typecheck_match_non_exhaustive_is_err() {
        let src = format!(
            "{SHAPE}\n(define (area [s : Shape]) : i64 \
               (match s [(Circle r) r]))"
        );
        let err = check(&src).unwrap_err();
        assert!(err.msg.contains("non-exhaustive"), "got: {}", err.msg);
    }

    #[test]
    fn test_typecheck_match_binding_arity_is_err() {
        // Circle has one payload field; binding two is an error.
        let src = format!(
            "{SHAPE}\n(define (area [s : Shape]) : i64 \
               (match s [(Circle a b) 0] [_ 1]))"
        );
        let err = check(&src).unwrap_err();
        assert!(err.msg.contains("binds"), "got: {}", err.msg);
    }

    #[test]
    fn test_typecheck_match_on_non_enum_is_err() {
        let src = "(define (f [x : i64]) : i64 (match x [_ 0]))";
        let err = check(src).unwrap_err();
        assert!(err.msg.contains("must be an enum"), "got: {}", err.msg);
    }

    #[test]
    fn test_typecheck_recursive_enum_rejected() {
        let src = "(defenum List (Cons i64 List) (Nil))\n(define (f [l : List]) : i64 0)";
        let err = check(src).unwrap_err();
        assert!(err.msg.contains("recursive enum"), "got: {}", err.msg);
    }
}
