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
        globals.insert(
            "print-char".into(),
            Type::Func(vec![Type::Char], Box::new(Type::Unit)),
        );
        globals.insert(
            "print-newline".into(),
            Type::Func(vec![], Box::new(Type::Unit)),
        );
        // `(string-length s)` / `(length s)` -> the byte length of a string.
        globals.insert(
            "string-length".into(),
            Type::Func(vec![Type::String], Box::new(Type::I64)),
        );
        globals.insert(
            "length".into(),
            Type::Func(vec![Type::String], Box::new(Type::I64)),
        );
        // `(string-eq a b)` / `(string=? a b)` -> byte-wise string equality.
        globals.insert(
            "string-eq".into(),
            Type::Func(vec![Type::String, Type::String], Box::new(Type::Bool)),
        );
        globals.insert(
            "string=?".into(),
            Type::Func(vec![Type::String, Type::String], Box::new(Type::Bool)),
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
                    if type_contains_enum(&inferred) {
                        return Err(TypeError::at(
                            "global definitions with enum values are not yet supported \
                             because enum constructors currently produce stack-owned storage",
                            value.span(),
                        ));
                    }
                    if type_contains_string_value(&inferred) {
                        return Err(TypeError::at(
                            "global definitions with string values are not yet supported \
                             because string literals currently produce stack-owned storage",
                            value.span(),
                        ));
                    }
                    if type_contains_dyn_array_value(&inferred) {
                        return Err(TypeError::at(
                            "global definitions with dynamic-array values are not yet supported \
                             because the fat array value is stack-owned storage",
                            value.span(),
                        ));
                    }
                    self.bind(name.clone(), inferred);
                }
                Decl::DefFn {
                    name,
                    params,
                    ret,
                    body,
                } => {
                    let ret = self.enums.resolve_type(ret);
                    if type_contains_enum(&ret) {
                        return Err(TypeError::at(
                            "functions returning enum values are not yet supported \
                             because enum constructors currently produce stack-owned storage",
                            body.span(),
                        ));
                    }
                    if type_contains_string_value(&ret) {
                        return Err(TypeError::at(
                            "functions returning string values are not yet supported \
                             because string literals currently produce stack-owned storage",
                            body.span(),
                        ));
                    }
                    if type_contains_dyn_array_value(&ret) {
                        return Err(TypeError::at(
                            "functions returning dynamic-array values are not yet supported \
                             because the fat array value is stack-owned storage",
                            body.span(),
                        ));
                    }
                    let func_ty = Type::Func(
                        params
                            .iter()
                            .map(|(_, t)| self.enums.resolve_type(t))
                            .collect(),
                        Box::new(ret),
                    );
                    self.bind(name.clone(), func_ty);
                }
                Decl::Extern { name, ty } => {
                    let ty = self.enums.resolve_type(ty);
                    if type_contains_enum(&ty) {
                        return Err(TypeError::at(
                            "extern declarations involving enum values are not yet supported",
                            Span::default(),
                        ));
                    }
                    self.bind(name.clone(), ty);
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
                Literal::String(_) => Ok(Type::String),
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
                // `(array-length a)` / `(length a)` over a dynamic array are
                // builtins over the fat value's `len` field, yielding an i64.
                // Handled here (not via a fixed-signature global) so the element
                // type stays free. `length` is overloaded: on a String it falls
                // through to the registered `(-> String i64)` builtin below;
                // `array-length` requires a dynamic array.
                if let Expr::Var(name) = func.unspan()
                    && (name == "array-length" || name == "length")
                    && args.len() == 1
                {
                    let arg_ty = self.check_expr(&args[0])?;
                    if let Type::DynArray(_) = arg_ty {
                        return Ok(Type::I64);
                    }
                    if name == "array-length" {
                        return Err(TypeError::at(
                            format!("{} requires a dynamic array, got {}", name, arg_ty),
                            args[0].span(),
                        ));
                    }
                    // `length` on a non-array: defer to the String builtin.
                }
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
                if type_contains_enum(&ret_ty) {
                    return Err(TypeError::at(
                        "lambdas returning enum values are not yet supported \
                         because enum constructors currently produce stack-owned storage",
                        body.span(),
                    ));
                }
                if type_contains_string_value(&ret_ty) {
                    return Err(TypeError::at(
                        "lambdas returning string values are not yet supported \
                         because string literals currently produce stack-owned storage",
                        body.span(),
                    ));
                }
                if type_contains_dyn_array_value(&ret_ty) {
                    return Err(TypeError::at(
                        "lambdas returning dynamic-array values are not yet supported \
                         because the fat array value is stack-owned storage",
                        body.span(),
                    ));
                }
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
            Expr::MakeArray { elem_ty, len } => {
                let elem_ty = self.enums.resolve_type(elem_ty);
                let len_ty = self.check_expr(len)?;
                if !len_ty.is_integer() {
                    return Err(TypeError::at(
                        format!("make-array length must be integer, got {}", len_ty),
                        len.span(),
                    ));
                }
                if !is_dyn_array_elem_supported(&elem_ty) {
                    return Err(TypeError::at(
                        format!(
                            "make-array element type {} is not yet supported \
                             (dynamic arrays currently hold scalar elements)",
                            elem_ty
                        ),
                        span,
                    ));
                }
                Ok(Type::DynArray(Box::new(elem_ty)))
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
                    Type::Array(elem_ty, _) | Type::DynArray(elem_ty) => Ok(*elem_ty),
                    _ => Err(TypeError::at(
                        format!("array-ref requires array type, got {}", arr_ty),
                        expr.span(),
                    )),
                }
            }
            Expr::StringRef { expr, index } => {
                // `(string-ref s i)` / `(char-at s i)` : `(-> String i64 char)`.
                let str_ty = self.check_expr(expr)?;
                if str_ty != Type::String {
                    return Err(TypeError::at(
                        format!("string-ref requires String, got {}", str_ty),
                        expr.span(),
                    ));
                }
                let idx_ty = self.check_expr(index)?;
                if !idx_ty.is_integer() {
                    return Err(TypeError::at(
                        format!("string index must be integer, got {}", idx_ty),
                        index.span(),
                    ));
                }
                Ok(Type::Char)
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
        if arms.is_empty() {
            return Err(TypeError::at("match must have at least one arm", span));
        }
        match &scrut_ty {
            Type::Enum(n) => self.check_match_enum(n.clone(), arms, span),
            // A scalar (non-enum) scrutinee is matched by literal patterns plus
            // a catch-all (`_`), e.g. `(match n [0 ..] [1 ..] [_ ..])`.
            other => self.check_match_scalar(other.clone(), scrutinee, arms, span),
        }
    }

    /// Type-check a `match` whose scrutinee is a scalar value, using literal and
    /// wildcard patterns. Variant patterns are rejected (no enum), and the match
    /// must end with a wildcard since the scalar value space is unbounded.
    fn check_match_scalar(
        &mut self,
        scrut_ty: Type,
        scrutinee: &Expr,
        arms: &[(Pattern, Expr)],
        span: Span,
    ) -> Result<Type, TypeError> {
        let mut result_ty: Option<Type> = None;
        let mut has_wildcard = false;

        for (pat, body) in arms {
            if has_wildcard {
                return Err(TypeError::at(
                    "unreachable match arm after wildcard `_`",
                    body.span(),
                ));
            }
            self.push_scope();
            match pat {
                Pattern::Wildcard => has_wildcard = true,
                Pattern::Literal(lit) => {
                    let lit_ty = Self::literal_pattern_type(lit);
                    // An integer literal pattern matches any integer-width
                    // scrutinee; otherwise the literal and scrutinee types must
                    // agree.
                    let ok = if matches!(lit, Literal::Int(_)) {
                        scrut_ty.is_integer()
                    } else {
                        self.types_equal(&scrut_ty, &lit_ty)
                    };
                    if !ok {
                        self.pop_scope();
                        return Err(TypeError::at(
                            format!(
                                "literal pattern of type {} does not match scrutinee type {}",
                                lit_ty, scrut_ty
                            ),
                            body.span(),
                        ));
                    }
                }
                other => {
                    self.pop_scope();
                    return Err(TypeError::at(
                        format!(
                            "match on scalar type {} only allows literal or `_` patterns, got {:?}",
                            scrut_ty, other
                        ),
                        scrutinee.span(),
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

        if !has_wildcard {
            return Err(TypeError::at(
                format!("non-exhaustive match on {}: add a `_` arm", scrut_ty),
                span,
            ));
        }
        Ok(result_ty.unwrap_or(Type::Unit))
    }

    /// The `Type` a literal pattern matches against. Integer literals report
    /// `I64` but are accepted against any integer width by the caller.
    fn literal_pattern_type(lit: &Literal) -> Type {
        match lit {
            Literal::Int(_) => Type::I64,
            Literal::Float(_) => Type::F64,
            Literal::Bool(_) => Type::Bool,
            Literal::Char(_) => Type::Char,
            Literal::String(_) => Type::String,
            Literal::Unit => Type::Unit,
        }
    }

    fn check_match_enum(
        &mut self,
        enum_name: String,
        arms: &[(Pattern, Expr)],
        span: Span,
    ) -> Result<Type, TypeError> {
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
            (Type::DynArray(a), Type::DynArray(b)) => self.types_equal(a, b),
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
        Type::DynArray(elem) => type_mentions_enum(elem, name),
        _ => false,
    }
}

fn type_contains_enum(ty: &Type) -> bool {
    match ty {
        Type::Enum(_) => true,
        Type::Func(args, ret) => args.iter().any(type_contains_enum) || type_contains_enum(ret),
        Type::Tuple(elems) => elems.iter().any(type_contains_enum),
        Type::Array(elem, _) => type_contains_enum(elem),
        Type::DynArray(elem) => type_contains_enum(elem),
        _ => false,
    }
}

/// Whether `ty` is (or nests) a `String`. A string literal's fat `{ptr,len}`
/// storage is constructed in a stack slot of the *current* function, so —
/// exactly like an enum constructor's storage — it must not escape via a
/// global initializer or a function/lambda return (that would dangle). String
/// *parameters* are fine: the caller owns the storage. This restriction is
/// lifted once strings are heap-allocated (deferred to #13).
fn type_contains_string_value(ty: &Type) -> bool {
    match ty {
        Type::String => true,
        Type::Tuple(elems) => elems.iter().any(type_contains_string_value),
        Type::Array(elem, _) => type_contains_string_value(elem),
        Type::DynArray(elem) => type_contains_string_value(elem),
        _ => false,
    }
}

/// Whether `ty` is (or nests) a dynamic array value. The fat `{ ptr, len }`
/// value is built in a stack slot of the *current* function (only the element
/// buffer it points at is heap-allocated via `tl_alloc`), so — like an enum
/// constructor or string literal — it must not escape via a global initializer
/// or a function/lambda return (the fat value would dangle). Dynamic-array
/// *parameters* are fine: the caller owns the fat value's storage.
fn type_contains_dyn_array_value(ty: &Type) -> bool {
    match ty {
        Type::DynArray(_) => true,
        Type::Func(args, ret) => {
            args.iter().any(type_contains_dyn_array_value) || type_contains_dyn_array_value(ret)
        }
        Type::Tuple(elems) => elems.iter().any(type_contains_dyn_array_value),
        Type::Array(elem, _) => type_contains_dyn_array_value(elem),
        _ => false,
    }
}

/// Whether a dynamic array may hold elements of `ty`. This slice supports
/// scalar element types (integers, bool, char, f64) — exactly the types the
/// backend can `Load`/`Store` through a computed element address. Nested
/// arrays, tuples, enums and strings are deferred (see #13).
fn is_dyn_array_elem_supported(ty: &Type) -> bool {
    ty.is_integer() || matches!(ty, Type::Bool | Type::Char | Type::F64)
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
    fn test_typecheck_builtin_char_and_newline_prints() {
        let prog = parse(
            r#"
            (define (main) : i64
              (begin
                (print-char #A')
                (print-newline)
                0))
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
        let src = format!("{SHAPE}\n(define (n) : i64 (match Nothing [Nothing 1] [_ 0]))");
        assert!(check(&src).is_ok());
    }

    #[test]
    fn test_typecheck_enum_return_is_rejected() {
        let src = format!("{SHAPE}\n(define (mk) : Shape (Circle 1))");
        let err = check(&src).unwrap_err();
        assert!(
            err.msg.contains("returning enum values"),
            "got: {}",
            err.msg
        );
    }

    #[test]
    fn test_typecheck_constructor_arity_checked() {
        // Circle takes one i64; calling with none is an arity error via the
        // ordinary call path.
        let src = format!(
            "{SHAPE}\n\
             (define (area [s : Shape]) : i64 (match s [_ 0]))\n\
             (define (c) : i64 (area (Circle)))"
        );
        assert!(check(&src).is_err());
    }

    #[test]
    fn test_typecheck_constructor_arg_type_checked() {
        let src = format!(
            "{SHAPE}\n\
             (define (area [s : Shape]) : i64 (match s [_ 0]))\n\
             (define (c) : i64 (area (Circle true)))"
        );
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
    fn test_typecheck_match_scalar_with_wildcard_is_ok() {
        // A scalar (non-enum) scrutinee is now a valid match target when an
        // arm makes it exhaustive (here, the catch-all `_`).
        let src = "(define (f [x : i64]) : i64 (match x [_ 0]))";
        assert!(check(src).is_ok());
    }

    // ------------------------------------------------------------------
    // Literal patterns on scalar scrutinees — extends #41
    // ------------------------------------------------------------------

    #[test]
    fn test_typecheck_match_int_literals_well_typed() {
        let src = "(define (classify [n : i64]) : i64 \
                     (match n [0 100] [1 200] [_ 0]))";
        assert!(check(src).is_ok());
    }

    #[test]
    fn test_typecheck_match_bool_literals_well_typed() {
        let src = "(define (f [b : bool]) : i64 (match b [true 1] [false 0]))";
        // bool literals do not need a wildcard if both values are covered? No:
        // exhaustiveness over scalars always requires a `_`. This match has no
        // wildcard, so it must be rejected.
        assert!(check(src).is_err());
    }

    #[test]
    fn test_typecheck_match_bool_literals_with_wildcard_ok() {
        let src = "(define (f [b : bool]) : i64 (match b [true 1] [_ 0]))";
        assert!(check(src).is_ok());
    }

    #[test]
    fn test_typecheck_match_scalar_non_exhaustive_is_err() {
        // No catch-all on an unbounded scalar space.
        let src = "(define (f [n : i64]) : i64 (match n [0 1] [1 2]))";
        let err = check(src).unwrap_err();
        assert!(err.msg.contains("non-exhaustive"), "got: {}", err.msg);
    }

    #[test]
    fn test_typecheck_match_literal_type_mismatch_is_err() {
        // A bool literal pattern against an i64 scrutinee is rejected.
        let src = "(define (f [n : i64]) : i64 (match n [true 1] [_ 0]))";
        let err = check(src).unwrap_err();
        assert!(
            err.msg.contains("does not match scrutinee type"),
            "got: {}",
            err.msg
        );
    }

    #[test]
    fn test_typecheck_match_scalar_arm_type_mismatch_is_err() {
        let src = "(define (f [n : i64]) : i64 (match n [0 1] [_ true]))";
        let err = check(src).unwrap_err();
        assert!(err.msg.contains("different types"), "got: {}", err.msg);
    }

    #[test]
    fn test_typecheck_match_unreachable_after_wildcard_is_err() {
        let src = "(define (f [n : i64]) : i64 (match n [_ 0] [1 2]))";
        let err = check(src).unwrap_err();
        assert!(err.msg.contains("unreachable"), "got: {}", err.msg);
    }

    #[test]
    fn test_typecheck_match_int_literals_narrow_width_ok() {
        // An integer literal pattern matches any integer-width scrutinee.
        let src = "(define (f [n : u8]) : i64 (match n [0 1] [_ 0]))";
        assert!(check(src).is_ok());
    }

    #[test]
    fn test_typecheck_recursive_enum_rejected() {
        let src = "(defenum List (Cons i64 List) (Nil))\n(define (f [l : List]) : i64 0)";
        let err = check(src).unwrap_err();
        assert!(err.msg.contains("recursive enum"), "got: {}", err.msg);
    }

    // ------------------------------------------------------------------
    // Strings — Issue #13
    // ------------------------------------------------------------------

    #[test]
    fn test_typecheck_string_literal_has_string_type() {
        // A function taking a String and returning its length via the builtin
        // `string-length` type-checks: literal -> String, length -> i64.
        let src = r#"(define (n) : i64 (string-length "hello"))"#;
        assert!(check(src).is_ok());
    }

    #[test]
    fn test_typecheck_length_alias() {
        let src = r#"(define (n) : i64 (length "hi"))"#;
        assert!(check(src).is_ok());
    }

    #[test]
    fn test_typecheck_string_length_on_param() {
        // String *parameters* are allowed (the caller owns the storage).
        let src = "(define (len [s : String]) : i64 (string-length s))";
        assert!(check(src).is_ok());
    }

    #[test]
    fn test_typecheck_string_length_arg_type_checked() {
        // `string-length` requires a String argument; an i64 is rejected.
        let src = "(define (n) : i64 (string-length 42))";
        assert!(check(src).is_err());
    }

    #[test]
    fn test_typecheck_string_eq_is_bool() {
        // `(string-eq a b)` of two Strings type-checks to bool.
        let src = r#"(define (n) : bool (string-eq "hi" "hi"))"#;
        assert!(check(src).is_ok());
    }

    #[test]
    fn test_typecheck_string_eq_question_alias() {
        // `string=?` is the Scheme-style alias and behaves identically.
        let src = r#"(define (n) : bool (string=? "a" "b"))"#;
        assert!(check(src).is_ok());
    }

    #[test]
    fn test_typecheck_string_eq_on_params() {
        // String parameters compare fine (caller owns the storage).
        let src = "(define (cmp [a : String] [b : String]) : bool (string-eq a b))";
        assert!(check(src).is_ok());
    }

    #[test]
    fn test_typecheck_string_eq_arg_type_checked() {
        // Both operands must be String; an i64 operand is rejected.
        let src = r#"(define (n) : bool (string-eq "a" 42))"#;
        assert!(check(src).is_err());
    }

    #[test]
    fn test_typecheck_string_eq_arity_checked() {
        // `string-eq` is binary; a single argument is an arity error.
        let src = r#"(define (n) : bool (string-eq "a"))"#;
        assert!(check(src).is_err());
    }

    #[test]
    fn test_typecheck_string_eq_result_not_i64() {
        // The result is bool, not i64 — using it where i64 is expected fails.
        let src = r#"(define (n) : i64 (string-eq "a" "a"))"#;
        assert!(check(src).is_err());
    }

    #[test]
    fn test_typecheck_string_return_is_rejected() {
        // Returning a string is not yet supported (stack-owned storage), like
        // returning an enum.
        let src = r#"(define (mk) : String "hi")"#;
        let err = check(src).unwrap_err();
        assert!(
            err.msg.contains("returning string values"),
            "got: {}",
            err.msg
        );
    }

    #[test]
    fn test_typecheck_string_global_is_rejected() {
        let src = r#"(define greeting "hello")"#;
        let err = check(src).unwrap_err();
        assert!(err.msg.contains("string values"), "got: {}", err.msg);
    }

    // ------------------------------------------------------------------
    // Dynamic arrays — Issue #13
    // ------------------------------------------------------------------

    #[test]
    fn test_typecheck_make_array_yields_dyn_array() {
        // `(make-array i64 n)` : (Array i64). A function taking the result and
        // reading its length type-checks.
        let src = "(define (f [n : i64]) : i64 (length (make-array i64 n)))";
        assert!(check(src).is_ok());
    }

    #[test]
    fn test_typecheck_make_array_length_must_be_integer() {
        let src = "(define (f) : i64 (length (make-array i64 true)))";
        let err = check(src).unwrap_err();
        assert!(
            err.msg.contains("length must be integer"),
            "got: {}",
            err.msg
        );
    }

    #[test]
    fn test_typecheck_array_ref_on_dyn_array_yields_elem() {
        let src = "(define (f [a : (Array i64)] [i : i64]) : i64 (array-ref a i))";
        assert!(check(src).is_ok());
    }

    #[test]
    fn test_typecheck_array_ref_index_must_be_integer() {
        let src = "(define (f [a : (Array i64)]) : i64 (array-ref a true))";
        let err = check(src).unwrap_err();
        assert!(
            err.msg.contains("index must be integer"),
            "got: {}",
            err.msg
        );
    }

    #[test]
    fn test_typecheck_length_requires_dyn_array() {
        let src = "(define (f [n : i64]) : i64 (array-length n))";
        let err = check(src).unwrap_err();
        assert!(
            err.msg.contains("requires a dynamic array"),
            "got: {}",
            err.msg
        );
    }

    #[test]
    fn test_typecheck_dyn_array_return_is_rejected() {
        // Returning a dynamic-array value is not yet supported (stack-owned fat
        // value), like returning an enum or string.
        let src = "(define (mk [n : i64]) : (Array i64) (make-array i64 n))";
        let err = check(src).unwrap_err();
        assert!(
            err.msg.contains("returning dynamic-array values"),
            "got: {}",
            err.msg
        );
    }

    #[test]
    fn test_typecheck_dyn_array_param_is_allowed() {
        // Dynamic-array parameters are fine: the caller owns the fat value.
        let src = "(define (sum [a : (Array i64)] [len : i64]) : i64 (array-ref a 0))";
        assert!(check(src).is_ok());
    }

    #[test]
    fn test_typecheck_fixed_array_still_works() {
        // The pre-existing fixed-size `(Array elem N)` type and `array-ref` over
        // it must keep type-checking.
        let src = "(define (f [a : (Array i64 3)]) : i64 (array-ref a 0))";
        assert!(check(src).is_ok());
    }

    // ------------------------------------------------------------------
    // String indexing — `string-ref` / `char-at` (Issue #13)
    // ------------------------------------------------------------------

    #[test]
    fn test_typecheck_string_ref_yields_char() {
        // `(string-ref s i)` : `(-> String i64 char)`. Feeding the result to
        // `print-char` (which expects a `char`) proves the inferred type.
        let src = "(define (f [s : String] [i : i64]) : unit (print-char (string-ref s i)))";
        assert!(check(src).is_ok());
    }

    #[test]
    fn test_typecheck_char_at_is_alias_for_string_ref() {
        let src = "(define (f [s : String] [i : i64]) : unit (print-char (char-at s i)))";
        assert!(check(src).is_ok());
    }

    #[test]
    fn test_typecheck_string_ref_requires_string() {
        // The collection argument must be a String, not an array or scalar.
        let src = "(define (f [a : (Array i64)] [i : i64]) : unit (print-char (string-ref a i)))";
        let err = check(src).unwrap_err();
        assert!(
            err.msg.contains("string-ref requires String"),
            "got: {}",
            err.msg
        );
    }

    #[test]
    fn test_typecheck_string_ref_index_must_be_integer() {
        let src = r#"(define (f) : unit (print-char (string-ref "hi" true)))"#;
        let err = check(src).unwrap_err();
        assert!(
            err.msg.contains("string index must be integer"),
            "got: {}",
            err.msg
        );
    }

    #[test]
    fn test_typecheck_string_ref_result_is_not_i64() {
        // The result is a `char`, so using it where an `i64` is required (the
        // function's declared return) is a type error.
        let src = r#"(define (f) : i64 (string-ref "hi" 0))"#;
        assert!(check(src).is_err());
    }
}
