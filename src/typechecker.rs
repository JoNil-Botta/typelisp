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
    structs: StructRegistry,
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
        // `(string->int s)` -> the i64 the decimal string `s` denotes. Skips an
        // optional leading `-`, then accumulates `acc*10 + (c - '0')` over the
        // remaining bytes. Non-digit bytes and overflow are not yet validated
        // (deferred); the conversion is the lexer's numeric-literal primitive.
        globals.insert(
            "string->int".into(),
            Type::Func(vec![Type::String], Box::new(Type::I64)),
        );
        // `(int->string n)` -> the decimal text of an i64 as a String. The
        // companion of `string->int`; returning a String is now permitted (the
        // lowerer heap-promotes escaping aggregates, see #85).
        globals.insert(
            "int->string".into(),
            Type::Func(vec![Type::I64], Box::new(Type::String)),
        );
        // `(substring s start len)` / `(string-slice s start len)` ->
        // `(-> String i64 i64 String)` — a fresh String holding the `len` bytes
        // of `s` beginning at byte offset `start` (a half-open `[start,
        // start+len)` slice expressed as start+length, which is the simplest
        // form to bounds-check). The range is bounds-checked at runtime
        // (UNSIGNED, so a negative `start`/`len` wraps to a huge value and
        // traps); out-of-range slices abort via `tl_oob_abort`. The lexer slices
        // identifier/number lexemes out of the source String with this. The fat
        // `{ ptr, len }` result is heap-allocated so it outlives the caller.
        globals.insert(
            "substring".into(),
            Type::Func(
                vec![Type::String, Type::I64, Type::I64],
                Box::new(Type::String),
            ),
        );
        globals.insert(
            "string-slice".into(),
            Type::Func(
                vec![Type::String, Type::I64, Type::I64],
                Box::new(Type::String),
            ),
        );
        // `(panic msg)` / `(error msg)` -> write `msg` to fd 2 (stderr) then
        // terminate the process. It never returns; its type is `(-> String unit)`
        // so a `(panic ...)` expression yields unit and can appear wherever a
        // unit-valued expression is expected (e.g. an `if` branch reporting bad
        // lexer input). `error` is an alias with identical behavior.
        globals.insert(
            "panic".into(),
            Type::Func(vec![Type::String], Box::new(Type::Unit)),
        );
        globals.insert(
            "error".into(),
            Type::Func(vec![Type::String], Box::new(Type::Unit)),
        );
        TypeChecker {
            env: vec![globals],
            func_ret: None,
            enums: EnumRegistry::default(),
            structs: StructRegistry::default(),
        }
    }

    /// Resolve a parsed type so that any `Type::Var` naming a declared enum or
    /// struct becomes the corresponding nominal `Type::Enum`/`Type::Struct`.
    /// Chains both registries (a name resolves to whichever declared it).
    fn resolve_type(&self, ty: &Type) -> Type {
        self.structs.resolve_type(&self.enums.resolve_type(ty))
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
        // Build the enum and struct registries up front so declared types and
        // constructors can be resolved/registered in the first pass.
        self.enums = EnumRegistry::from_program(prog);
        self.structs = StructRegistry::from_program(prog);

        // Recursive enums (refs #13/#27). A *direct* self-referential payload
        // field — a variant field whose type IS the enclosing enum (`(EAdd Expr
        // Expr)` in `defenum Expr`) — is now supported: an enum value is a
        // pointer (`Type::size` reports 8), so such a field occupies an 8-byte
        // heap-pointer slot. The layout stays finite (the recursive field counts
        // as 8 bytes, never re-expanded), construction `tl_alloc`s each child
        // node and stores its pointer, and a `match` arm loads the field back as
        // a pointer typed as the enum — usable in a nested match or a recursive
        // call. This is the keystone for tree-shaped ASTs.
        //
        // Recursion reached only *indirectly* — through another aggregate that
        // is laid out inline (a tuple/array directly carrying the enum, or a
        // mutually-recursive struct field) — is still deferred: those storage
        // paths need the inline-vs-pointer and escape interactions worked out
        // beyond this slice. Such a field is rejected with a clear diagnostic
        // rather than miscompiled. (A field that is itself a *pointer-sized*
        // aggregate value — `(Array Expr)` dyn array, another enum/struct — is
        // fine; only inline-carrying compounds are rejected.)
        for decl in &prog.decls {
            if let Decl::DefEnum { name, variants } = decl {
                for v in variants {
                    for f in &v.fields {
                        let resolved = self.enums.resolve_type(f);
                        // A direct self-reference (`Type::Enum(name)`) is the
                        // supported case; skip it. Only flag recursion buried
                        // inside an inline-carrying compound type.
                        if type_mentions_enum_indirectly(&resolved, name) {
                            return Err(TypeError::at(
                                format!(
                                    "recursive enum '{}' (variant '{}') via an inline compound \
                                     type is not yet supported; reference the enum directly \
                                     (it is heap-pointer-indirected) — see #13",
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
                    let fields: Vec<Type> = v.fields.iter().map(|t| self.resolve_type(t)).collect();
                    let ctor_ty = if fields.is_empty() {
                        Type::Enum(name.clone())
                    } else {
                        Type::Func(fields, Box::new(Type::Enum(name.clone())))
                    };
                    self.bind(v.name.clone(), ctor_ty);
                }
            }
        }

        // Recursive structs (a field whose type references the struct itself,
        // directly or via a compound type) require heap indirection and are out
        // of scope for this slice (deferred). Reject them rather than looping
        // forever computing the inline layout.
        for decl in &prog.decls {
            if let Decl::DefStruct { name, fields } = decl {
                for f in fields {
                    if type_mentions_struct(&self.resolve_type(&f.ty), name) {
                        return Err(TypeError::at(
                            format!(
                                "recursive struct '{}' (field '{}') is not yet supported \
                                 (needs heap indirection)",
                                name, f.name
                            ),
                            Span::default(),
                        ));
                    }
                }
            }
        }

        // Register struct constructors as callable functions: a struct `Name`
        // with fields `f1:T1 .. fn:Tn` is bound as `Name : (-> T1 .. Tn Name)`,
        // so a construction `(Name v1 .. vn)` type-checks through the ordinary
        // call path (arity + per-argument checks come for free), exactly like an
        // enum variant constructor.
        for decl in &prog.decls {
            if let Decl::DefStruct { name, fields } = decl {
                let field_tys: Vec<Type> =
                    fields.iter().map(|f| self.resolve_type(&f.ty)).collect();
                let ctor_ty = Type::Func(field_tys, Box::new(Type::Struct(name.clone())));
                self.bind(name.clone(), ctor_ty);
            }
        }

        // First pass: collect all declarations
        for decl in &prog.decls {
            match decl {
                Decl::Def { name, ty, value } => {
                    let inferred = if let Some(ty) = ty {
                        let ty = self.resolve_type(ty);
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
                    if type_contains_struct_value(&inferred) {
                        return Err(TypeError::at(
                            "global definitions with struct values are not yet supported \
                             because struct constructors currently produce stack-owned storage",
                            value.span(),
                        ));
                    }
                    self.bind(name.clone(), inferred);
                }
                Decl::DefFn {
                    name,
                    params,
                    ret,
                    // The body is checked in the second pass below; this pass
                    // only binds the function signature.
                    body: _,
                } => {
                    let ret = self.resolve_type(ret);
                    // Returning enum / String / DynArray values is now supported:
                    // the lowerer heap-promotes (via `tl_alloc`) the storage for
                    // aggregate constructors that can escape via `return`, so the
                    // returned pointer outlives the frame instead of dangling
                    // (see `type_kind_escapes_via_return` in src/lower.rs). The
                    // former hard rejections here have been lifted. Escapes via
                    // *global* initializers / *extern* values are still rejected
                    // (those storage paths are not yet heap-promoted).
                    let func_ty = Type::Func(
                        params.iter().map(|(_, t)| self.resolve_type(t)).collect(),
                        Box::new(ret),
                    );
                    self.bind(name.clone(), func_ty);
                }
                Decl::Extern { name, ty } => {
                    let ty = self.resolve_type(ty);
                    if type_contains_enum(&ty) {
                        return Err(TypeError::at(
                            "extern declarations involving enum values are not yet supported",
                            Span::default(),
                        ));
                    }
                    self.bind(name.clone(), ty);
                }
                Decl::DefEnum { .. } => {}
                // Struct constructors were registered above (as `Name`
                // functions); the declaration itself emits no value here.
                Decl::DefStruct { .. } => {}
                // Import directives are stripped by the module-graph loader
                // before typecheck; this arm is defensive (no codegen effect).
                Decl::Import(_) => {}
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
                    self.bind(param.clone(), self.resolve_type(ty));
                }
                let ret = self.resolve_type(ret);
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
                    let ty = ty.as_ref().map(|t| self.resolve_type(t));
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
                if type_contains_struct_value(&ret_ty) {
                    return Err(TypeError::at(
                        "lambdas returning struct values are not yet supported \
                         because struct constructors currently produce stack-owned storage",
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
                let elem_ty = self.resolve_type(elem_ty);
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
            Expr::ArraySet { expr, index, value } => {
                // `(array-set! arr i v)` : `(-> (Array T) i64 T Unit)`. The store
                // mirrors `array-ref`'s read: same array/index requirements, plus
                // the stored value's type must match the element type.
                let arr_ty = self.check_expr(expr)?;
                let idx_ty = self.check_expr(index)?;
                if !idx_ty.is_integer() {
                    return Err(TypeError::at(
                        format!("array index must be integer, got {}", idx_ty),
                        index.span(),
                    ));
                }
                let elem_ty = match arr_ty {
                    Type::Array(elem_ty, _) | Type::DynArray(elem_ty) => *elem_ty,
                    _ => {
                        return Err(TypeError::at(
                            format!("array-set! requires array type, got {}", arr_ty),
                            expr.span(),
                        ));
                    }
                };
                let val_ty = self.check_expr(value)?;
                if !self.types_equal(&elem_ty, &val_ty) {
                    return Err(TypeError::at(
                        format!(
                            "array-set! value type mismatch: array holds {}, got {}",
                            elem_ty, val_ty
                        ),
                        value.span(),
                    ));
                }
                Ok(Type::Unit)
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
                let ty = self.resolve_type(ty);
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
            Expr::StructGet { expr, field } => {
                // `(struct-get s field)`: `s` must be a struct value declaring
                // `field`; the result is the field's declared type.
                let s_ty = self.check_expr(expr)?;
                let Type::Struct(name) = &s_ty else {
                    return Err(TypeError::at(
                        format!("struct-get requires a struct value, got {}", s_ty),
                        expr.span(),
                    ));
                };
                match self.structs.lookup_field(name, field) {
                    Some((_idx, fty)) => Ok(fty.clone()),
                    None => Err(TypeError::at(
                        format!("struct '{}' has no field '{}'", name, field),
                        span,
                    )),
                }
            }
            Expr::Cast { expr, ty } => {
                let ty = self.resolve_type(ty);
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
                    // Resolve each payload field type before binding so a
                    // nominal payload (a struct/enum named in the `defenum`,
                    // parsed as `Type::Var`) becomes its concrete
                    // `Type::Struct`/`Type::Enum`. Without this the bound
                    // variable stays an unresolved type variable and downstream
                    // operations that require a concrete aggregate (e.g.
                    // `struct-get` on a struct payload) wrongly reject it. The
                    // lowerer already resolves these types the same way.
                    let field_tys: Vec<Type> =
                        fields.iter().map(|t| self.resolve_type(t)).collect();
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

/// Whether `ty` (after enum resolution) reaches the enum named `name` only
/// *indirectly*, through a compound type that would lay the enum out **inline**
/// rather than behind its natural pointer. Used to reject the still-unsupported
/// recursive-enum shapes while permitting the supported direct one.
///
/// A *direct* self-reference — `ty == Type::Enum(name)` — is the supported case
/// (an enum value is pointer-sized, so the field is an 8-byte heap pointer); it
/// returns `false`. So do pointer-sized aggregate boundaries that re-introduce
/// indirection: a `(Array Expr)` dynamic array (the value is a pointer to a heap
/// buffer of 8-byte element pointers) and a function type (a code pointer).
///
/// Only the *inline-carrying* compounds are descended into and flagged:
///
///   * `Type::Tuple` — laid out as its elements end-to-end (inline), so an enum
///     element would be embedded by value, not behind a pointer.
///   * `Type::Array(_, n)` — a fixed-size array stores `n` elements inline.
///
/// Reaching `name` at any depth beneath one of those returns `true`.
fn type_mentions_enum_indirectly(ty: &Type, name: &str) -> bool {
    // Does `ty` refer to `name` anywhere (direct or nested)? Helper for the
    // inline-compound descent below.
    fn mentions(ty: &Type, name: &str) -> bool {
        match ty {
            Type::Enum(n) => n == name,
            Type::Func(args, ret) => args.iter().any(|a| mentions(a, name)) || mentions(ret, name),
            Type::Tuple(elems) => elems.iter().any(|e| mentions(e, name)),
            Type::Array(elem, _) => mentions(elem, name),
            Type::DynArray(elem) => mentions(elem, name),
            _ => false,
        }
    }
    match ty {
        // Direct self-reference: supported (heap-pointer slot). Not "indirect".
        Type::Enum(_) => false,
        // Pointer-sized aggregate boundaries keep the enum behind a pointer, so
        // they are fine even when they carry the enum.
        Type::DynArray(_) | Type::Func(_, _) => false,
        // Inline-carrying compounds: any mention of the enum beneath them is the
        // unsupported inline-recursive shape.
        Type::Tuple(elems) => elems.iter().any(|e| mentions(e, name)),
        Type::Array(elem, _) => mentions(elem, name),
        _ => false,
    }
}

/// Whether `ty` (after resolution) refers to the struct named `name`, directly
/// or nested inside a compound type. Used to reject recursive structs.
fn type_mentions_struct(ty: &Type, name: &str) -> bool {
    match ty {
        Type::Struct(n) => n == name,
        Type::Func(args, ret) => {
            args.iter().any(|a| type_mentions_struct(a, name)) || type_mentions_struct(ret, name)
        }
        Type::Tuple(elems) => elems.iter().any(|e| type_mentions_struct(e, name)),
        Type::Array(elem, _) => type_mentions_struct(elem, name),
        Type::DynArray(elem) => type_mentions_struct(elem, name),
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

/// Whether `ty` is (or nests) a struct value. A struct constructor's inline
/// field storage is built in a stack slot of the *current* function (unless
/// heap-promoted for a function `return`, per #85), so — like an enum
/// constructor or string literal — it must not escape via a global initializer
/// or a lambda return (that would dangle). Struct *parameters* are fine: the
/// caller owns the storage.
fn type_contains_struct_value(ty: &Type) -> bool {
    match ty {
        Type::Struct(_) => true,
        Type::Tuple(elems) => elems.iter().any(type_contains_struct_value),
        Type::Array(elem, _) => type_contains_struct_value(elem),
        Type::DynArray(elem) => type_contains_struct_value(elem),
        _ => false,
    }
}

/// Whether a dynamic array may hold elements of `ty` (after nominal
/// resolution). Two element categories are supported:
///
/// * Scalars (integers, bool, char, f64) — stored inline by value; the backend
///   `Load`/`Store`s them through a computed element address at their natural
///   width.
/// * Aggregates (enum, struct, String, and nested dynamic arrays) — each is a
///   pointer-sized value (8 bytes; see `Type::size`), so the element buffer
///   holds one *pointer per element*. `array-set!` stores that pointer and
///   `array-ref` loads it back typed as the aggregate element type. Stride and
///   Load/Store width both come from `Type::size`, which already reports 8 for
///   these, so no representation is special-cased here. This lets a dynamic
///   array hold, e.g., a real `Token` stream (refs #13/#27/#41).
///
/// Still deferred: fixed-size nested `(Array T N)`, tuples, `f32`, and
/// unresolved type variables (`Type::Var`) — their inline/by-value element
/// layout is a separate slice.
fn is_dyn_array_elem_supported(ty: &Type) -> bool {
    ty.is_integer()
        || matches!(
            ty,
            Type::Bool
                | Type::Char
                | Type::F64
                | Type::Enum(_)
                | Type::Struct(_)
                | Type::String
                | Type::DynArray(_)
        )
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

    /// Concatenate two parsed modules into one `Program`, stripping imports,
    /// mirroring what the module-graph loader produces (module `a` first).
    fn concat_modules(a: &str, b: &str) -> Program {
        let mut decls: Vec<Decl> = Vec::new();
        for src in [a, b] {
            for d in parse(src).unwrap().decls {
                if !matches!(d, Decl::Import(_)) {
                    decls.push(d);
                }
            }
        }
        Program { decls }
    }

    #[test]
    fn test_typecheck_cross_module_call_ok() {
        // Module b defines a function that calls a function defined in module a.
        // The concatenated program must typecheck (first pass registers both
        // top-level names before bodies are checked).
        let prog = concat_modules(
            "(define (a [x : i64]) : i64 (+ x 1))",
            "(import \"a.tl\")\n(define (b) : i64 (a 41))",
        );
        let mut tc = TypeChecker::new();
        assert!(tc.check_program(&prog).is_ok());
    }

    #[test]
    fn test_typecheck_cross_module_call_wrong_type_errors() {
        // Calling module a's i64 function with a bool argument is a type error
        // even across module boundaries.
        let prog = concat_modules(
            "(define (a [x : i64]) : i64 (+ x 1))",
            "(import \"a.tl\")\n(define (b) : i64 (a true))",
        );
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
    fn test_typecheck_string_payload_variant_construct_return_match() {
        // GAP (1): an enum variant whose payload is a `String` is constructible
        // (`(TIdent s)`), returnable from a function (heap-promoted), and the
        // payload binds back out at type `String` in a `match` arm so a
        // String-only operation (`string-length`) type-checks. Unblocks lexer
        // identifier/keyword tokens.
        let src = "(defenum Token (TIdent String) (TEnd))\n\
                   (define (mk [s : String]) : Token (TIdent s))\n\
                   (define (idlen [t : Token]) : i64 \
                     (match t [(TIdent s) (string-length s)] [(TEnd) 0]))";
        assert!(check(src).is_ok());
    }

    #[test]
    fn test_typecheck_string_payload_match_binds_string_type() {
        // The bound payload is exactly a `String`, so using it where an i64 is
        // required (the arm body's type) is rejected — i.e. the binding is not
        // an opaque type variable that unifies with anything.
        let src = "(defenum Token (TIdent String) (TEnd))\n\
                   (define (bad [t : Token]) : i64 \
                     (match t [(TIdent s) s] [(TEnd) 0]))";
        assert!(check(src).is_err());
    }

    #[test]
    fn test_typecheck_struct_payload_variant_match_struct_get() {
        // GAP (1), "or other aggregate": a variant payload that is a *struct*
        // (a nominal name in the `defenum`, parsed as `Type::Var`) must resolve
        // to its concrete `Type::Struct` when bound in a `match` arm, so
        // `struct-get` on the bound payload type-checks. Previously the binding
        // kept its unresolved `Type::Var("Pos")` and `struct-get` wrongly
        // reported "requires a struct value".
        let src = "(defstruct Pos (line i64) (col i64))\n\
                   (defenum Tok (TPos Pos) (TEnd))\n\
                   (define (line-of [t : Tok]) : i64 \
                     (match t [(TPos p) (struct-get p line)] [(TEnd) -1]))";
        assert!(check(src).is_ok());
    }

    #[test]
    fn test_typecheck_struct_payload_variant_construct_and_return() {
        // Constructing a struct-payload variant and returning it type-checks
        // (both the enum and the nested struct are heap-promoted by the
        // lowerer when the value escapes via the return).
        let src = "(defstruct Pos (line i64) (col i64))\n\
                   (defenum Tok (TPos Pos) (TEnd))\n\
                   (define (mk [l : i64]) : Tok (TPos (Pos l 7)))";
        assert!(check(src).is_ok());
    }

    #[test]
    fn test_typecheck_enum_return_is_accepted() {
        // Returning an enum value is now accepted: the lowerer heap-promotes the
        // constructor storage so the returned pointer outlives the frame. This
        // was previously a hard rejection ("returning enum values are not yet
        // supported"); that guard has been lifted (heap-promote escaping
        // aggregates, refs #13/#45).
        let src = format!("{SHAPE}\n(define (mk) : Shape (Circle 1))");
        assert!(check(&src).is_ok());
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
    fn test_typecheck_recursive_enum_direct_ok() {
        // refs #13/#27: a directly self-referential payload (`List` field inside
        // `List`) is now accepted — the field is an 8-byte heap-pointer slot.
        let src = "(defenum List (Cons i64 List) (Nil))\n(define (f [l : List]) : i64 0)";
        assert!(check(src).is_ok());
    }

    #[test]
    fn test_typecheck_recursive_enum_expr_tree_ok() {
        // The keystone shape: a binary AST node referencing the enum twice.
        // Constructing, returning, and matching all type-check.
        let src = "(defenum Expr (ENum i64) (EAdd Expr Expr))\n\
                   (define (mk) : Expr (EAdd (ENum 1) (ENum 2)))\n\
                   (define (eval [e : Expr]) : i64 \
                     (match e [(ENum n) n] [(EAdd l r) (+ (eval l) (eval r))]))";
        assert!(check(src).is_ok());
    }

    #[test]
    fn test_typecheck_recursive_enum_build_eval_returns_ok() {
        // `(EAdd (ENum 1) (ENum 2))` constructs through the ordinary call path:
        // each child `(ENum _)` yields an `Expr`, accepted as an `EAdd` field.
        let src = "(defenum Expr (ENum i64) (EAdd Expr Expr))\n\
                   (define (one) : Expr (EAdd (ENum 1) (ENum 2)))";
        assert!(check(src).is_ok());
    }

    #[test]
    fn test_typecheck_recursive_enum_inline_tuple_rejected() {
        // Recursion buried in an *inline-carrying* tuple is still deferred:
        // the enum would be embedded by value, not behind its pointer.
        let src = "(defenum Bad (V (Tuple Bad i64)) (Nil))\n(define (f [b : Bad]) : i64 0)";
        let err = check(src).unwrap_err();
        assert!(err.msg.contains("inline compound"), "got: {}", err.msg);
    }

    #[test]
    fn test_typecheck_recursive_enum_indirect_array_rejected() {
        // A fixed-size array stores elements inline; recursion through it is
        // likewise deferred.
        let src = "(defenum Bad (V (Array Bad 2)) (Nil))\n(define (f [b : Bad]) : i64 0)";
        let err = check(src).unwrap_err();
        assert!(err.msg.contains("inline compound"), "got: {}", err.msg);
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
    fn test_typecheck_string_to_int_is_i64() {
        // `(string->int s)` : `(-> String i64)` — parsing a string literal
        // type-checks where an i64 is expected.
        let src = r#"(define (n) : i64 (string->int "42"))"#;
        assert!(check(src).is_ok());
    }

    #[test]
    fn test_typecheck_string_to_int_on_param() {
        // A String *parameter* parses fine (the caller owns the storage).
        let src = "(define (parse [s : String]) : i64 (string->int s))";
        assert!(check(src).is_ok());
    }

    #[test]
    fn test_typecheck_string_to_int_arg_type_checked() {
        // The argument must be a String; an i64 operand is rejected.
        let src = "(define (n) : i64 (string->int 42))";
        assert!(check(src).is_err());
    }

    #[test]
    fn test_typecheck_string_to_int_arity_checked() {
        // `string->int` is unary; a second argument is an arity error.
        let src = r#"(define (n) : i64 (string->int "1" "2"))"#;
        assert!(check(src).is_err());
    }

    #[test]
    fn test_typecheck_string_to_int_result_not_bool() {
        // The result is i64, not bool — using it where bool is expected fails.
        let src = r#"(define (n) : bool (string->int "1"))"#;
        assert!(check(src).is_err());
    }

    #[test]
    fn test_typecheck_string_return_is_accepted() {
        // Returning a string is now accepted: the lowerer heap-promotes the fat
        // string storage so the returned pointer outlives the frame. This was
        // previously a hard rejection ("returning string values are not yet
        // supported"); that guard has been lifted (refs #13/#45).
        let src = r#"(define (mk) : String "hi")"#;
        assert!(check(src).is_ok());
    }

    #[test]
    fn test_typecheck_string_global_is_rejected() {
        let src = r#"(define greeting "hello")"#;
        let err = check(src).unwrap_err();
        assert!(err.msg.contains("string values"), "got: {}", err.msg);
    }

    #[test]
    fn test_typecheck_int_to_string_yields_string() {
        // `(int->string n)` : `(-> i64 String)`. A function returning the result
        // type-checks (String returns are now accepted, refs #13/#45).
        let src = "(define (f [n : i64]) : String (int->string n))";
        assert!(check(src).is_ok());
    }

    #[test]
    fn test_typecheck_int_to_string_on_literal() {
        // The argument may be any i64 expression, including a literal.
        let src = "(define (f) : String (int->string 42))";
        assert!(check(src).is_ok());
    }

    #[test]
    fn test_typecheck_int_to_string_arg_type_checked() {
        // The operand must be an i64; a String operand is rejected.
        let src = r#"(define (f) : String (int->string "x"))"#;
        let err = check(src).unwrap_err();
        assert!(err.msg.contains("argument type"), "got: {}", err.msg);
    }

    #[test]
    fn test_typecheck_int_to_string_arity_checked() {
        // `int->string` is unary; two arguments is an arity error.
        let src = "(define (f) : String (int->string 1 2))";
        let err = check(src).unwrap_err();
        assert!(err.msg.contains("arguments"), "got: {}", err.msg);
    }

    #[test]
    fn test_typecheck_int_to_string_result_is_not_i64() {
        // The result is a String, not an i64; using it where an i64 is required
        // (a function's i64 return) is a mismatch.
        let src = "(define (f) : i64 (int->string 5))";
        assert!(check(src).is_err());
    }

    // ------------------------------------------------------------------
    // substring / string-slice — `(-> String i64 i64 String)` (refs #13/#27)
    // ------------------------------------------------------------------

    #[test]
    fn test_typecheck_substring_yields_string() {
        // `(substring s start len)` : `(-> String i64 i64 String)`. Slicing a
        // String parameter and returning it type-checks as a String result.
        let src = "(define (f [s : String] [a : i64] [b : i64]) : String (substring s a b))";
        assert!(check(src).is_ok());
    }

    #[test]
    fn test_typecheck_string_slice_alias_yields_string() {
        // `string-slice` is the alias of `substring` with identical type.
        let src = "(define (f [s : String] [a : i64] [b : i64]) : String (string-slice s a b))";
        assert!(check(src).is_ok());
    }

    #[test]
    fn test_typecheck_substring_on_literal() {
        // A String literal slices fine (constant start/len).
        let src = r#"(define (f) : String (substring "hello" 1 3))"#;
        assert!(check(src).is_ok());
    }

    #[test]
    fn test_typecheck_substring_requires_string_first_arg() {
        // The first argument must be a String, not an i64.
        let src = "(define (f) : String (substring 42 0 1))";
        assert!(check(src).is_err());
    }

    #[test]
    fn test_typecheck_substring_start_must_be_integer() {
        // The start offset must be an i64; a bool is rejected.
        let src = r#"(define (f) : String (substring "hi" true 1))"#;
        assert!(check(src).is_err());
    }

    #[test]
    fn test_typecheck_substring_len_must_be_integer() {
        // The slice length must be an i64; a bool is rejected.
        let src = r#"(define (f) : String (substring "hi" 0 true))"#;
        assert!(check(src).is_err());
    }

    #[test]
    fn test_typecheck_substring_arity_checked() {
        // `substring` is ternary; two arguments is an arity error.
        let src = r#"(define (f) : String (substring "hi" 0))"#;
        assert!(check(src).is_err());
    }

    #[test]
    fn test_typecheck_substring_result_is_not_i64() {
        // The result is a String, not an i64; using it where an i64 is required
        // (the function's declared return) is a type error.
        let src = r#"(define (f) : i64 (substring "hi" 0 1))"#;
        assert!(check(src).is_err());
    }

    // ------------------------------------------------------------------
    // panic / error — Issue #45
    // ------------------------------------------------------------------

    #[test]
    fn test_typecheck_panic_is_unit() {
        // `(panic msg)` : `(-> String unit)` — a string-literal message yields
        // unit, so it type-checks as the body of a unit-returning function.
        let src = r#"(define (f) : unit (panic "bad input"))"#;
        assert!(check(src).is_ok());
    }

    #[test]
    fn test_typecheck_error_alias_is_unit() {
        // `error` is the alias of `panic` with identical `(-> String unit)` type.
        let src = r#"(define (f) : unit (error "bad input"))"#;
        assert!(check(src).is_ok());
    }

    #[test]
    fn test_typecheck_panic_on_param() {
        // A String *parameter* is a valid panic message (the caller owns it).
        let src = "(define (f [m : String]) : unit (panic m))";
        assert!(check(src).is_ok());
    }

    #[test]
    fn test_typecheck_panic_arg_type_checked() {
        // The message must be a String; an i64 operand is rejected.
        let src = "(define (f) : unit (panic 42))";
        assert!(check(src).is_err());
    }

    #[test]
    fn test_typecheck_panic_arity_checked() {
        // `panic` is unary; a second argument is an arity error.
        let src = r#"(define (f) : unit (panic "a" "b"))"#;
        assert!(check(src).is_err());
    }

    #[test]
    fn test_typecheck_panic_result_not_i64() {
        // The result is unit, not i64 — using it where i64 is expected fails.
        let src = r#"(define (f) : i64 (panic "boom"))"#;
        assert!(check(src).is_err());
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

    // ------------------------------------------------------------------
    // Aggregate mutation — `array-set!` (Issues #13/#18)
    // ------------------------------------------------------------------

    #[test]
    fn test_typecheck_array_set_yields_unit() {
        // `(array-set! a i v)` : `(-> (Array T) i64 T Unit)`.
        let src = "(define (f [a : (Array i64)] [i : i64] [v : i64]) : unit (array-set! a i v))";
        assert!(check(src).is_ok());
    }

    #[test]
    fn test_typecheck_array_set_index_must_be_integer() {
        let src = "(define (f [a : (Array i64)] [v : i64]) : unit (array-set! a true v))";
        let err = check(src).unwrap_err();
        assert!(
            err.msg.contains("index must be integer"),
            "got: {}",
            err.msg
        );
    }

    #[test]
    fn test_typecheck_array_set_value_must_match_element() {
        // Storing a `bool` into an `(Array i64)` is rejected.
        let src = "(define (f [a : (Array i64)] [i : i64]) : unit (array-set! a i true))";
        let err = check(src).unwrap_err();
        assert!(err.msg.contains("value type mismatch"), "got: {}", err.msg);
    }

    #[test]
    fn test_typecheck_array_set_requires_array() {
        let src = "(define (f [n : i64] [v : i64]) : unit (array-set! n 0 v))";
        let err = check(src).unwrap_err();
        assert!(
            err.msg.contains("array-set! requires array type"),
            "got: {}",
            err.msg
        );
    }

    #[test]
    fn test_typecheck_array_set_on_fixed_array_works() {
        // Fixed-size `(Array elem N)` is also accepted by the typechecker.
        let src = "(define (f [a : (Array i64 3)] [v : i64]) : unit (array-set! a 0 v))";
        assert!(check(src).is_ok());
    }

    // ------------------------------------------------------------------
    // Dynamic arrays of AGGREGATE elements (enum / struct / String).
    // An aggregate value is a pointer (8 bytes), so the element buffer holds
    // one pointer per element; the typechecker now accepts these element types
    // in make-array/array-ref/array-set! (refs #13/#27/#41).
    // ------------------------------------------------------------------

    #[test]
    fn test_typecheck_make_array_of_enum_ok() {
        // `(make-array <Enum> n)` type-checks; the result is `(Array <Enum>)`.
        let src =
            format!("{SHAPE}\n(define (f [n : i64]) : i64 (array-length (make-array Shape n)))");
        assert!(check(&src).is_ok());
    }

    #[test]
    fn test_typecheck_make_array_of_struct_ok() {
        let src =
            format!("{POINT}\n(define (f [n : i64]) : i64 (array-length (make-array Point n)))");
        assert!(check(&src).is_ok());
    }

    #[test]
    fn test_typecheck_make_array_of_string_ok() {
        let src = "(define (f [n : i64]) : i64 (array-length (make-array String n)))";
        assert!(check(src).is_ok());
    }

    #[test]
    fn test_typecheck_array_set_enum_element_ok() {
        // Storing a constructed enum value into an `(Array <Enum>)` is accepted.
        let src = format!(
            "{SHAPE}\n(define (f [a : (Array Shape)] [i : i64]) : unit (array-set! a i (Circle 3)))"
        );
        assert!(check(&src).is_ok());
    }

    #[test]
    fn test_typecheck_array_set_enum_element_wrong_type_rejected() {
        // The stored value is still checked against the element type: a `bool`
        // does not match the enum element type.
        let src = format!(
            "{SHAPE}\n(define (f [a : (Array Shape)] [i : i64]) : unit (array-set! a i true))"
        );
        let err = check(&src).unwrap_err();
        assert!(err.msg.contains("value type mismatch"), "got: {}", err.msg);
    }

    #[test]
    fn test_typecheck_array_ref_enum_element_returns_enum_usable_in_match() {
        // `array-ref` over `(Array <Enum>)` yields the element ENUM type, so the
        // result can be `match`ed and a payload bound back out (the lexer's
        // "read the i-th token then dispatch on its variant" pattern).
        let src = format!(
            "{SHAPE}\n(define (f [a : (Array Shape)] [i : i64]) : i64 \
             (match (array-ref a i) [(Circle r) r] [(Square s) s] [Nothing 0]))"
        );
        assert!(check(&src).is_ok());
    }

    #[test]
    fn test_typecheck_array_ref_struct_element_returns_struct_usable_in_field_access() {
        // `array-ref` over `(Array <Struct>)` yields the element STRUCT type, so
        // a field can be read off the result.
        let src = format!(
            "{POINT}\n(define (f [a : (Array Point)] [i : i64]) : i64 \
             (struct-get (array-ref a i) x))"
        );
        assert!(check(&src).is_ok());
    }

    #[test]
    fn test_typecheck_make_array_of_enum_via_let_construct_match() {
        // End-to-end: build an enum array, store a constructed variant, read it
        // back, and match on it — the full lexer-token-stream usage pattern.
        let src = format!(
            "{SHAPE}\n(define (main) : i64 \
             (let ([arr (make-array Shape 2)]) \
               (begin \
                 (array-set! arr 0 (Circle 7)) \
                 (array-set! arr 1 Nothing) \
                 (match (array-ref arr 0) [(Circle r) r] [(Square s) s] [Nothing 0]))))"
        );
        assert!(check(&src).is_ok());
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
    fn test_typecheck_dyn_array_return_is_accepted() {
        // Returning a dynamic-array value is now accepted: the lowerer
        // heap-promotes the fat `{ ptr, len }` value (the element buffer was
        // already heap) so the returned pointer outlives the frame. This was
        // previously a hard rejection ("returning dynamic-array values are not
        // yet supported"); that guard has been lifted (refs #13/#45).
        let src = "(define (mk [n : i64]) : (Array i64) (make-array i64 n))";
        assert!(check(src).is_ok());
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

    // ------------------------------------------------------------------
    // Structs / records — Issue #18
    // ------------------------------------------------------------------

    const POINT: &str = "(defstruct Point (x i64) (y i64))";

    #[test]
    fn test_typecheck_struct_construct_and_access_well_typed() {
        // Construct with correct field types and read a field back as i64.
        let src = format!(
            "{POINT}\n(define (f [p : Point]) : i64 \
               (+ (struct-get p x) (struct-get p y)))"
        );
        assert!(check(&src).is_ok());
    }

    #[test]
    fn test_typecheck_struct_construct_returns_struct_type() {
        // A construction `(Point 1 2)` annotated as Point type-checks; returning
        // it is accepted (heap-promoted, like enums/strings).
        let src = format!("{POINT}\n(define (mk) : Point (Point 1 2))");
        assert!(check(&src).is_ok());
    }

    #[test]
    fn test_typecheck_struct_constructor_arity_checked() {
        // Point takes two i64s; one argument is an arity error via the call path.
        let src = format!("{POINT}\n(define (f) : Point (Point 1))");
        assert!(check(&src).is_err());
    }

    #[test]
    fn test_typecheck_struct_constructor_arg_type_checked() {
        // Field types are checked: a bool where an i64 is expected is an error.
        let src = format!("{POINT}\n(define (f) : Point (Point 1 true))");
        assert!(check(&src).is_err());
    }

    #[test]
    fn test_typecheck_struct_field_access_returns_field_type() {
        // A struct with a bool field: `struct-get` of that field is a bool, so
        // feeding it to a bool-returning function type-checks.
        let src = "(defstruct Flagged (n i64) (ok bool))\n\
                   (define (f [s : Flagged]) : bool (struct-get s ok))";
        assert!(check(src).is_ok());
    }

    #[test]
    fn test_typecheck_struct_field_access_wrong_use_is_err() {
        // `(struct-get p x)` is an i64; using it where a bool is required fails.
        let src = format!("{POINT}\n(define (f [p : Point]) : bool (struct-get p x))");
        assert!(check(&src).is_err());
    }

    #[test]
    fn test_typecheck_struct_unknown_field_is_err() {
        let src = format!("{POINT}\n(define (f [p : Point]) : i64 (struct-get p z))");
        let err = check(&src).unwrap_err();
        assert!(err.msg.contains("has no field 'z'"), "got: {}", err.msg);
    }

    #[test]
    fn test_typecheck_struct_get_requires_struct() {
        // `struct-get` on a non-struct value (an i64) is rejected.
        let src = "(define (f [n : i64]) : i64 (struct-get n x))";
        let err = check(src).unwrap_err();
        assert!(
            err.msg.contains("requires a struct value"),
            "got: {}",
            err.msg
        );
    }

    #[test]
    fn test_typecheck_unknown_struct_is_unbound() {
        // Referencing an undeclared struct as a constructor is an unbound var.
        let src = "(define (f) : i64 (struct-get (Nope 1) x))";
        assert!(check(src).is_err());
    }

    #[test]
    fn test_typecheck_struct_param_is_allowed() {
        // Struct *parameters* are fine: the caller owns the storage.
        let src = format!("{POINT}\n(define (getx [p : Point]) : i64 (struct-get p x))");
        assert!(check(&src).is_ok());
    }

    #[test]
    fn test_typecheck_struct_global_is_rejected() {
        // A global initialized to a struct value is rejected (stack-owned
        // constructor storage), mirroring the enum/string global guard.
        let src = format!("{POINT}\n(define origin (Point 0 0))");
        let err = check(&src).unwrap_err();
        assert!(err.msg.contains("struct values"), "got: {}", err.msg);
    }

    #[test]
    fn test_typecheck_recursive_struct_rejected() {
        let src = "(defstruct Node (next Node) (val i64))\n\
                   (define (f [n : Node]) : i64 (struct-get n val))";
        let err = check(src).unwrap_err();
        assert!(err.msg.contains("recursive struct"), "got: {}", err.msg);
    }

    #[test]
    fn test_typecheck_struct_field_of_struct_type() {
        // A struct field whose type is another (non-recursive) struct resolves
        // to a nominal struct type and type-checks.
        let src = "(defstruct Inner (a i64))\n\
                   (defstruct Outer (inner Inner) (b i64))\n\
                   (define (f [o : Outer]) : i64 (struct-get o b))";
        assert!(check(src).is_ok());
    }

    // --- boolean logic ops (not / and / or, bool equality) ---

    #[test]
    fn test_typecheck_not_of_bool_is_bool() {
        // `(not b)` over a bool is well-typed and yields a bool.
        assert!(check("(define (f [b : bool]) : bool (not b))").is_ok());
        assert!(check("(define (f) : bool (not true))").is_ok());
    }

    #[test]
    fn test_typecheck_not_of_non_bool_errors() {
        // `(not 5)` is rejected: `not` requires a bool operand.
        let err = check("(define (f) : bool (not 5))").unwrap_err();
        assert!(err.msg.contains("not requires bool"), "got: {}", err.msg);
    }

    #[test]
    fn test_typecheck_and_or_of_bools_is_bool() {
        // `(and a b)` / `(or a b)` over bools are well-typed and yield bool.
        assert!(check("(define (f [a : bool] [b : bool]) : bool (and a b))").is_ok());
        assert!(check("(define (f [a : bool] [b : bool]) : bool (or a b))").is_ok());
    }

    #[test]
    fn test_typecheck_and_or_of_non_bool_errors() {
        // A non-bool operand to `and`/`or` is a type error.
        let err = check("(define (f [a : bool]) : bool (and a 1))").unwrap_err();
        assert!(
            err.msg.contains("logical operator requires bool"),
            "got: {}",
            err.msg
        );
        let err = check("(define (f [a : bool]) : bool (or 1 a))").unwrap_err();
        assert!(
            err.msg.contains("logical operator requires bool"),
            "got: {}",
            err.msg
        );
    }

    #[test]
    fn test_typecheck_bool_equality_is_bool() {
        // Comparing two bools with `=` is well-typed and yields a bool.
        assert!(check("(define (f [a : bool] [b : bool]) : bool (= a b))").is_ok());
    }

    #[test]
    fn test_typecheck_bool_equality_mixed_type_errors() {
        // Comparing a bool to an i64 is a comparison type mismatch.
        let err = check("(define (f [a : bool]) : bool (= a 1))").unwrap_err();
        assert!(
            err.msg.contains("comparison type mismatch"),
            "got: {}",
            err.msg
        );
    }
}
