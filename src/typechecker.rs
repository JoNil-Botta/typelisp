use crate::ast::*;
use crate::diagnostic::Diagnostic;
use crate::span::Span;
use crate::types::Type;
use std::collections::{HashMap, HashSet};
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
        // `(print-string s)` / `(print-str s)` -> write a String's bytes to fd 1
        // (stdout) via a `write(2)` syscall, then yield unit. The companion of
        // `print-char`/`print-newline` for whole strings; unblocks printing
        // String values (e.g. the interpreter's VStr). `print-str` is an alias.
        globals.insert(
            "print-string".into(),
            Type::Func(vec![Type::String], Box::new(Type::Unit)),
        );
        globals.insert(
            "print-str".into(),
            Type::Func(vec![Type::String], Box::new(Type::Unit)),
        );
        globals.insert(
            "print-error".into(),
            Type::Func(vec![Type::String], Box::new(Type::Unit)),
        );
        // Bootstrap-driver primitives: observe the Linux process argv that the
        // backend preserves from `_start`. `(arg i)` returns a heap-owned String.
        globals.insert("arg-count".into(), Type::Func(vec![], Box::new(Type::I64)));
        globals.insert(
            "arg".into(),
            Type::Func(vec![Type::I64], Box::new(Type::String)),
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
        // `(read-file path)` -> the full file contents as a heap-owned String.
        // V1 is Linux/compiler-driver oriented and panic-on-error; recoverable
        // file errors are deferred until the Result/Option model is settled.
        globals.insert(
            "read-file".into(),
            Type::Func(vec![Type::String], Box::new(Type::String)),
        );
        // `(write-file path contents)` -> write all contents bytes to path.
        // V1 mirrors `read-file`: Linux/compiler-driver oriented and
        // panic-on-error until recoverable file errors are designed.
        globals.insert(
            "write-file".into(),
            Type::Func(vec![Type::String, Type::String], Box::new(Type::Unit)),
        );
        // `(file-exists? path)` -> whether the path names an existing entry.
        // Missing paths return false; unexpected syscall/path failures keep the
        // v1 file-I/O panic-on-error convention.
        globals.insert(
            "file-exists?".into(),
            Type::Func(vec![Type::String], Box::new(Type::Bool)),
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
        // `(string-append a b)` / `(string-concat a b)` ->
        // `(-> String String String)` — a fresh String holding the bytes of `a`
        // immediately followed by the bytes of `b`. The fat `{ ptr, len }` result
        // is heap-allocated (via the emit-on-demand `tl_string_concat` runtime) so
        // it outlives the caller. `string-concat` is an alias with identical type.
        globals.insert(
            "string-append".into(),
            Type::Func(vec![Type::String, Type::String], Box::new(Type::String)),
        );
        globals.insert(
            "string-concat".into(),
            Type::Func(vec![Type::String, Type::String], Box::new(Type::String)),
        );
        // `(panic msg)` / `(error msg)` -> write `msg` to fd 2 (stderr) then
        // terminate the process. The builtin result is the compiler-internal
        // bottom type so a diverging expression can satisfy any expected type.
        // A user definition named `panic` or `error` shadows these builtins and
        // keeps its declared return type.
        globals.insert(
            "panic".into(),
            Type::Func(vec![Type::String], Box::new(Type::Never)),
        );
        globals.insert(
            "error".into(),
            Type::Func(vec![Type::String], Box::new(Type::Never)),
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

    fn resolve_type_checked(&self, ty: &Type, span: Span) -> Result<Type, TypeError> {
        let resolved = self.resolve_type(ty);
        Self::reject_unresolved_type_vars(&resolved, span)?;
        Ok(resolved)
    }

    fn reject_unresolved_type_vars(ty: &Type, span: Span) -> Result<(), TypeError> {
        match ty {
            Type::Var(name) if name == "type" => Err(TypeError::at(
                "unsupported type kind 'type'; comptime type values are not implemented yet",
                span,
            )),
            Type::Var(name) => Err(TypeError::at(format!("unknown type name '{}'", name), span)),
            Type::Func(args, ret) => {
                for arg in args {
                    Self::reject_unresolved_type_vars(arg, span)?;
                }
                Self::reject_unresolved_type_vars(ret, span)
            }
            Type::Tuple(elems) => {
                for elem in elems {
                    Self::reject_unresolved_type_vars(elem, span)?;
                }
                Ok(())
            }
            Type::Array(elem, _) | Type::DynArray(elem) | Type::Vector(elem, _) => {
                Self::reject_unresolved_type_vars(elem, span)
            }
            _ => Ok(()),
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

    fn outer_local_names(&self) -> HashSet<String> {
        self.env
            .iter()
            .skip(1)
            .flat_map(|scope| scope.keys().cloned())
            .collect()
    }

    fn push_capture(captures: &mut Vec<(String, Span)>, name: &str, span: Span) {
        if !captures.iter().any(|(existing, _)| existing == name) {
            captures.push((name.to_string(), span));
        }
    }

    fn collect_lambda_captures(
        expr: &Expr,
        outer_locals: &HashSet<String>,
        local_bindings: &HashSet<String>,
        captures: &mut Vec<(String, Span)>,
        captured_sets: &mut Vec<(String, Span)>,
    ) {
        match expr.unspan() {
            Expr::Literal(_) => {}
            Expr::Var(name) => {
                if outer_locals.contains(name) && !local_bindings.contains(name) {
                    Self::push_capture(captures, name, expr.span());
                }
            }
            Expr::Binary { lhs, rhs, .. } => {
                Self::collect_lambda_captures(
                    lhs,
                    outer_locals,
                    local_bindings,
                    captures,
                    captured_sets,
                );
                Self::collect_lambda_captures(
                    rhs,
                    outer_locals,
                    local_bindings,
                    captures,
                    captured_sets,
                );
            }
            Expr::Unary { expr, .. }
            | Expr::Ann { expr, .. }
            | Expr::Cast { expr, .. }
            | Expr::Comptime { expr }
            | Expr::TupleRef { expr, .. }
            | Expr::StructGet { expr, .. } => {
                Self::collect_lambda_captures(
                    expr,
                    outer_locals,
                    local_bindings,
                    captures,
                    captured_sets,
                );
            }
            Expr::Call { func, args } => {
                Self::collect_lambda_captures(
                    func,
                    outer_locals,
                    local_bindings,
                    captures,
                    captured_sets,
                );
                for arg in args {
                    Self::collect_lambda_captures(
                        arg,
                        outer_locals,
                        local_bindings,
                        captures,
                        captured_sets,
                    );
                }
            }
            Expr::If {
                cond,
                then_branch,
                else_branch,
            } => {
                Self::collect_lambda_captures(
                    cond,
                    outer_locals,
                    local_bindings,
                    captures,
                    captured_sets,
                );
                Self::collect_lambda_captures(
                    then_branch,
                    outer_locals,
                    local_bindings,
                    captures,
                    captured_sets,
                );
                Self::collect_lambda_captures(
                    else_branch,
                    outer_locals,
                    local_bindings,
                    captures,
                    captured_sets,
                );
            }
            Expr::Let { bindings, body } => {
                let mut scoped = local_bindings.clone();
                for (name, _, value) in bindings {
                    Self::collect_lambda_captures(
                        value,
                        outer_locals,
                        &scoped,
                        captures,
                        captured_sets,
                    );
                    scoped.insert(name.clone());
                }
                Self::collect_lambda_captures(body, outer_locals, &scoped, captures, captured_sets);
            }
            Expr::Lambda { params, body, .. } => {
                let mut scoped = local_bindings.clone();
                for (param, _) in params {
                    scoped.insert(param.clone());
                }
                Self::collect_lambda_captures(body, outer_locals, &scoped, captures, captured_sets);
            }
            Expr::Tuple(elems) | Expr::Array(elems) | Expr::Begin(elems) => {
                for elem in elems {
                    Self::collect_lambda_captures(
                        elem,
                        outer_locals,
                        local_bindings,
                        captures,
                        captured_sets,
                    );
                }
            }
            Expr::MakeArray { len, .. } => {
                Self::collect_lambda_captures(
                    len,
                    outer_locals,
                    local_bindings,
                    captures,
                    captured_sets,
                );
            }
            Expr::ArrayRef { expr, index } | Expr::StringRef { expr, index } => {
                Self::collect_lambda_captures(
                    expr,
                    outer_locals,
                    local_bindings,
                    captures,
                    captured_sets,
                );
                Self::collect_lambda_captures(
                    index,
                    outer_locals,
                    local_bindings,
                    captures,
                    captured_sets,
                );
            }
            Expr::ArraySet { expr, index, value } => {
                Self::collect_lambda_captures(
                    expr,
                    outer_locals,
                    local_bindings,
                    captures,
                    captured_sets,
                );
                Self::collect_lambda_captures(
                    index,
                    outer_locals,
                    local_bindings,
                    captures,
                    captured_sets,
                );
                Self::collect_lambda_captures(
                    value,
                    outer_locals,
                    local_bindings,
                    captures,
                    captured_sets,
                );
            }
            Expr::While { cond, body } => {
                Self::collect_lambda_captures(
                    cond,
                    outer_locals,
                    local_bindings,
                    captures,
                    captured_sets,
                );
                Self::collect_lambda_captures(
                    body,
                    outer_locals,
                    local_bindings,
                    captures,
                    captured_sets,
                );
            }
            Expr::Set(name, expr) => {
                if outer_locals.contains(name) && !local_bindings.contains(name) {
                    Self::push_capture(captures, name, expr.span());
                    captured_sets.push((name.clone(), expr.span()));
                }
                Self::collect_lambda_captures(
                    expr,
                    outer_locals,
                    local_bindings,
                    captures,
                    captured_sets,
                );
            }
            Expr::Match { scrutinee, arms } => {
                Self::collect_lambda_captures(
                    scrutinee,
                    outer_locals,
                    local_bindings,
                    captures,
                    captured_sets,
                );
                for (pat, body) in arms {
                    let mut scoped = local_bindings.clone();
                    Self::collect_pattern_bindings(pat, true, &mut scoped);
                    Self::collect_lambda_captures(
                        body,
                        outer_locals,
                        &scoped,
                        captures,
                        captured_sets,
                    );
                }
            }
            Expr::Foreach {
                index,
                start,
                end,
                body,
                ..
            } => {
                Self::collect_lambda_captures(
                    start,
                    outer_locals,
                    local_bindings,
                    captures,
                    captured_sets,
                );
                Self::collect_lambda_captures(
                    end,
                    outer_locals,
                    local_bindings,
                    captures,
                    captured_sets,
                );
                let mut scoped = local_bindings.clone();
                scoped.insert(index.clone());
                Self::collect_lambda_captures(body, outer_locals, &scoped, captures, captured_sets);
            }
            Expr::Spanned { expr, .. } => {
                Self::collect_lambda_captures(
                    expr,
                    outer_locals,
                    local_bindings,
                    captures,
                    captured_sets,
                );
            }
        }
    }

    fn capture_type_supported(&self, ty: &Type) -> bool {
        matches!(
            self.resolve_type(ty),
            Type::I64
                | Type::I32
                | Type::I16
                | Type::I8
                | Type::U64
                | Type::U32
                | Type::U16
                | Type::U8
                | Type::Bool
                | Type::Char
                | Type::F64
                | Type::Func(_, _)
        )
    }

    fn collect_pattern_bindings(pat: &Pattern, top_level: bool, bindings: &mut HashSet<String>) {
        match pat {
            Pattern::Var(name, _) => {
                bindings.insert(name.clone());
            }
            Pattern::Tuple(items) => {
                for item in items {
                    Self::collect_pattern_bindings(item, false, bindings);
                }
            }
            Pattern::Binding(name) if !top_level => {
                bindings.insert(name.clone());
            }
            Pattern::Variant { args, .. } => {
                for arg in args {
                    Self::collect_pattern_bindings(arg, false, bindings);
                }
            }
            Pattern::Wildcard | Pattern::Literal(_) | Pattern::Binding(_) => {}
        }
    }

    pub fn check_program(&mut self, prog: &Program) -> Result<(), TypeError> {
        // Build the enum and struct registries up front so declared types and
        // constructors can be resolved/registered in the first pass.
        self.enums = EnumRegistry::from_program(prog);
        self.structs = StructRegistry::from_program(prog);

        // Check for duplicate top-level names across the whole program.
        // Value-level names share the backend symbol namespace; nominal types
        // share the type-resolution namespace. Keep them separate so an enum
        // type can intentionally have a same-named constructor variant.
        let mut seen_values: HashMap<String, Span> = HashMap::new();
        let mut seen_types: HashMap<String, Span> = HashMap::new();
        for decl in &prog.decls {
            let type_name: Option<(String, Span)> = match decl {
                Decl::DefEnum { name, .. } | Decl::DefStruct { name, .. } => {
                    Some((name.clone(), Span::default()))
                }
                _ => None,
            };
            if let Some((name, span)) = type_name {
                if let Some(prev_span) = seen_types.get(&name) {
                    return Err(TypeError::at(
                        format!(
                            "duplicate top-level type name '{}' (already defined at {:?})",
                            name, prev_span,
                        ),
                        span,
                    ));
                }
                seen_types.insert(name, span);
            }

            let value_names: Vec<(String, Span)> = match decl {
                Decl::Def { name, value, .. } => {
                    vec![(name.clone(), value.span())]
                }
                Decl::DefFn { name, body, .. } => {
                    vec![(name.clone(), body.span())]
                }
                Decl::Extern { name, .. } => {
                    vec![(name.clone(), Span::default())]
                }
                Decl::DefEnum { name: _, variants } => variants
                    .iter()
                    .map(|v| (v.name.clone(), Span::default()))
                    .collect(),
                Decl::DefStruct { name, .. } => {
                    vec![(name.clone(), Span::default())]
                }
                Decl::Import(_) => vec![],
            };
            for (name, span) in value_names {
                if let Some(prev_span) = seen_values.get(&name) {
                    return Err(TypeError::at(
                        format!(
                            "duplicate top-level name '{}' (already defined at {:?})",
                            name, prev_span,
                        ),
                        span,
                    ));
                }
                seen_values.insert(name, span);
            }
        }

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
                        // A direct self-reference (`Type::Enum(name)`) is the
                        // supported case; skip it. Only flag recursion buried
                        // inside an inline-carrying compound type.
                        let resolved = self.resolve_type_checked(f, Span::default())?;
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
                    let fields: Vec<Type> = v
                        .fields
                        .iter()
                        .map(|t| self.resolve_type_checked(t, Span::default()))
                        .collect::<Result<_, _>>()?;
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
                    if type_mentions_struct(
                        &self.resolve_type_checked(&f.ty, Span::default())?,
                        name,
                    ) {
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
                let field_tys: Vec<Type> = fields
                    .iter()
                    .map(|f| self.resolve_type_checked(&f.ty, Span::default()))
                    .collect::<Result<_, _>>()?;
                let ctor_ty = Type::Func(field_tys, Box::new(Type::Struct(name.clone())));
                self.bind(name.clone(), ctor_ty);
            }
        }

        // First pass: collect all declarations
        for decl in &prog.decls {
            match decl {
                Decl::Def { name, ty, value } => {
                    let inferred = if let Some(ty) = ty {
                        let ty = self.resolve_type_checked(ty, value.span())?;
                        let val_ty = self.check_expr(value)?;
                        if !self.type_compatible(&ty, &val_ty) {
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
                    if let Some(reason) =
                        unsupported_global_aggregate_reason(&inferred, &self.enums, &self.structs)
                    {
                        return Err(TypeError::at(
                            format!(
                                "global definition '{}' has unsupported aggregate type {}: {}",
                                name, inferred, reason
                            ),
                            value.span(),
                        ));
                    }
                    self.bind(name.clone(), inferred);
                }
                Decl::DefFn {
                    name,
                    params,
                    ret,
                    // The body expression is checked in the second pass below;
                    // this pass only uses its span for signature diagnostics.
                    body,
                } => {
                    let ret = self.resolve_type_checked(ret, body.span())?;
                    // Returning enum / String / DynArray values is now supported:
                    // the lowerer heap-promotes (via `tl_alloc`) the storage for
                    // aggregate constructors that can escape via `return`, so the
                    // returned pointer outlives the frame instead of dangling
                    // (see `type_kind_escapes_via_return` in src/lower.rs). The
                    // former hard rejections here have been lifted. Runtime
                    // global initializers use the same hidden-function return
                    // path, so their aggregate results are heap-promoted too.
                    let func_ty = Type::Func(
                        params
                            .iter()
                            .map(|(_, t)| self.resolve_type_checked(t, body.span()))
                            .collect::<Result<_, _>>()?,
                        Box::new(ret),
                    );
                    self.bind(name.clone(), func_ty);
                }
                Decl::Extern { name, ty } => {
                    let ty = self.resolve_type_checked(ty, Span::default())?;
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
                    self.bind(param.clone(), self.resolve_type_checked(ty, body.span())?);
                }
                let ret = self.resolve_type_checked(ret, body.span())?;
                let old_ret = self.func_ret.clone();
                self.func_ret = Some(ret.clone());
                let body_ty = self.check_expr(body)?;
                self.func_ret = old_ret;
                self.pop_scope();

                if !self.type_compatible(&ret, &body_ty) {
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

    #[allow(dead_code)] // Used by the REPL command added in follow-up issues.
    pub fn check_repl_decl(session_decls: &[Decl], candidate: &Decl) -> Result<(), TypeError> {
        let mut decls = session_decls.to_vec();
        decls.push(candidate.clone());
        let program = Program { decls };
        let mut checker = Self::new();
        checker.check_program(&program)
    }

    #[allow(dead_code)] // Used by the REPL command added in follow-up issues.
    pub fn check_repl_expr(session_decls: &[Decl], expr: &Expr) -> Result<Type, TypeError> {
        let program = Program {
            decls: session_decls.to_vec(),
        };
        let mut checker = Self::new();
        checker.check_program(&program)?;
        checker.check_expr(expr)
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
            Expr::Comptime { .. } => Err(TypeError::at(
                "comptime is reserved for future compile-time evaluation and is not supported yet",
                span,
            )),
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
                            if !self.type_compatible(expected, &arg_ty) {
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
                    // `(Red)` — a zero-arg call form whose head is a nullary enum
                    // variant constructs that variant, equivalent to bare `Red`
                    // and consistent with payload construction `(RGB 5)`. The
                    // head resolved to `Type::Enum` (not `Type::Func`) precisely
                    // because nullary variants are bound as their enum type, so a
                    // genuine zero-arg `define`d function `(f)` — bound as
                    // `Type::Func` — is unaffected and still calls (the `Func`
                    // arm above takes precedence). A nullary variant given a
                    // non-empty arg list is an arity error.
                    Type::Enum(enum_name)
                        if matches!(func.unspan(), Expr::Var(name)
                            if self
                                .enums
                                .lookup_variant(name)
                                .is_some_and(|(owner, _, fields)| owner == enum_name && fields.is_empty())) =>
                    {
                        if !args.is_empty() {
                            let name = match func.unspan() {
                                Expr::Var(n) => n,
                                _ => unreachable!(),
                            };
                            return Err(TypeError::at(
                                format!(
                                    "nullary enum variant '{}' takes no arguments, got {}",
                                    name,
                                    args.len()
                                ),
                                span,
                            ));
                        }
                        Ok(Type::Enum(enum_name))
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
                if cond_ty == Type::Never {
                    self.check_expr(then_branch)?;
                    self.check_expr(else_branch)?;
                    return Ok(Type::Never);
                }
                if !self.type_compatible(&Type::Bool, &cond_ty) {
                    return Err(TypeError::at(
                        format!("if condition must be bool, got {}", cond_ty),
                        cond.span(),
                    ));
                }
                let then_ty = self.check_expr(then_branch)?;
                let else_ty = self.check_expr(else_branch)?;
                let Some(result_ty) = self.merge_branch_types(&then_ty, &else_ty) else {
                    return Err(TypeError::at(
                        format!(
                            "if branches have different types: {} and {}",
                            then_ty, else_ty
                        ),
                        span,
                    ));
                };
                Ok(result_ty)
            }
            Expr::Let { bindings, body } => {
                self.push_scope();
                for (name, ty, value) in bindings {
                    let val_ty = self.check_expr(value)?;
                    let ty = ty
                        .as_ref()
                        .map(|t| self.resolve_type_checked(t, value.span()))
                        .transpose()?;
                    let binding_ty = if let Some(expected) = &ty {
                        if !self.type_compatible(expected, &val_ty) {
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
                let outer_locals = self.outer_local_names();
                let lambda_bindings: HashSet<String> =
                    params.iter().map(|(param, _)| param.clone()).collect();
                let mut captures = Vec::new();
                let mut captured_sets = Vec::new();
                Self::collect_lambda_captures(
                    body,
                    &outer_locals,
                    &lambda_bindings,
                    &mut captures,
                    &mut captured_sets,
                );
                if let Some((captured, span)) = captured_sets.first() {
                    return Err(TypeError::at(
                        format!(
                            "set! to captured variable '{}' is not supported; captured lambdas use immutable snapshots",
                            captured
                        ),
                        *span,
                    ));
                }
                for (captured, span) in &captures {
                    let Some(ty) = self.lookup(captured) else {
                        continue;
                    };
                    if !self.capture_type_supported(&ty) {
                        return Err(TypeError::at(
                            format!(
                                "capturing value '{}' of type {} is not yet supported; capture scalar or function values only (see #435)",
                                captured, ty
                            ),
                            *span,
                        ));
                    }
                }

                self.push_scope();
                for (param, ty) in params {
                    self.bind(param.clone(), self.resolve_type_checked(ty, body.span())?);
                }
                let old_ret = self.func_ret.clone();
                let ret = ret
                    .as_ref()
                    .map(|ty| self.resolve_type_checked(ty, body.span()))
                    .transpose()?;
                self.func_ret = ret.clone();
                let body_ty = self.check_expr(body)?;
                self.func_ret = old_ret;
                self.pop_scope();

                let ret_ty = ret.clone().unwrap_or(body_ty.clone());
                if !self.type_compatible(&ret_ty, &body_ty) {
                    return Err(TypeError::at(
                        format!(
                            "lambda return type mismatch: expected {}, got {}",
                            ret_ty, body_ty
                        ),
                        body.span(),
                    ));
                }

                Ok(Type::Func(
                    params
                        .iter()
                        .map(|(_, t)| self.resolve_type_checked(t, body.span()))
                        .collect::<Result<_, _>>()?,
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
                let elem_ty = self.resolve_type_checked(elem_ty, span)?;
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
                if !self.type_compatible(&elem_ty, &val_ty) {
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
                if cond_ty == Type::Never {
                    self.check_expr(body)?;
                    return Ok(Type::Never);
                }
                if !self.type_compatible(&Type::Bool, &cond_ty) {
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
                if !self.type_compatible(&var_ty, &val_ty) {
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
                let ty = self.resolve_type_checked(ty, span)?;
                let expr_ty = self.check_expr(expr)?;
                if !self.type_compatible(&ty, &expr_ty) {
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
                    Some((_idx, fty)) => Ok(self.resolve_type(fty)),
                    None => Err(TypeError::at(
                        format!("struct '{}' has no field '{}'", name, field),
                        span,
                    )),
                }
            }
            Expr::Cast { expr, ty } => {
                let ty = self.resolve_type_checked(ty, span)?;
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
            Expr::Foreach {
                index,
                index_ty,
                start,
                end,
                body,
            } => {
                let index_ty = self.resolve_type_checked(index_ty, span)?;
                if !index_ty.is_integer() {
                    return Err(TypeError::at(
                        format!(
                            "foreach index type must be an integer type, got {}",
                            index_ty
                        ),
                        span,
                    ));
                }
                let start_ty = self.check_expr(start)?;
                let end_ty = self.check_expr(end)?;
                if !start_ty.is_integer() {
                    return Err(TypeError::at(
                        format!(
                            "foreach start expression must be an integer type, got {}",
                            start_ty
                        ),
                        start.span(),
                    ));
                }
                if !end_ty.is_integer() {
                    return Err(TypeError::at(
                        format!(
                            "foreach end expression must be an integer type, got {}",
                            end_ty
                        ),
                        end.span(),
                    ));
                }
                // NOTE: In a full SPMD implementation, `start` and `end` are
                // uniform expressions evaluated once.  For the first slice we
                // only require they type-check as integers; uniform/varying
                // inference and the richer restrictions are tracked in #344.
                self.push_scope();
                self.bind(index.clone(), index_ty);
                let body_ty = self.check_expr(body)?;
                self.pop_scope();
                if !self.type_compatible(&Type::Unit, &body_ty) {
                    return Err(TypeError::at(
                        format!("foreach body must have type unit, got {}", body_ty),
                        body.span(),
                    ));
                }
                Ok(Type::Unit)
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
            // a catch-all (`_`), except that bool is finite and can be covered
            // exactly by `true` and `false`.
            other => self.check_match_scalar(other.clone(), scrutinee, arms, span),
        }
    }

    /// Type-check a `match` whose scrutinee is a scalar value, using literal and
    /// wildcard patterns. Variant patterns are rejected (no enum). Unbounded
    /// scalar types must end with a wildcard, while bool can be exhausted by
    /// covering both literal values.
    fn check_match_scalar(
        &mut self,
        scrut_ty: Type,
        scrutinee: &Expr,
        arms: &[(Pattern, Expr)],
        span: Span,
    ) -> Result<Type, TypeError> {
        let mut result_ty: Option<Type> = None;
        let mut has_wildcard = false;
        let mut bool_literals_covered = [false; 2];

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
                    if let (Type::Bool, Literal::Bool(value)) = (&scrut_ty, lit) {
                        bool_literals_covered[*value as usize] = true;
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
                    let Some(merged) = self.merge_branch_types(expected, &body_ty) else {
                        return Err(TypeError::at(
                            format!(
                                "match arms have different types: {} and {}",
                                expected, body_ty
                            ),
                            body.span(),
                        ));
                    };
                    result_ty = Some(merged);
                }
            }
        }

        let bool_literals_are_exhaustive = matches!(scrut_ty, Type::Bool)
            && bool_literals_covered[false as usize]
            && bool_literals_covered[true as usize];

        if !has_wildcard && !bool_literals_are_exhaustive {
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
            if has_wildcard {
                return Err(TypeError::at(
                    "unreachable match arm after wildcard `_`",
                    body.span(),
                ));
            }
            self.push_scope();
            match pat {
                Pattern::Wildcard => {
                    has_wildcard = true;
                }
                // A bare top-level identifier is a nullary-variant arm
                // (`[Red 0]`): resolve it as the variant `name` with no args.
                Pattern::Binding(name) => {
                    let (tag, irrefutable) =
                        match self.check_variant_pattern(&enum_name, name, &[], body.span()) {
                            Ok(t) => t,
                            Err(e) => {
                                self.pop_scope();
                                return Err(e);
                            }
                        };
                    if irrefutable {
                        covered[tag] = true;
                    }
                }
                Pattern::Variant { name, args } => {
                    let (tag, irrefutable) =
                        match self.check_variant_pattern(&enum_name, name, args, body.span()) {
                            Ok(t) => t,
                            Err(e) => {
                                self.pop_scope();
                                return Err(e);
                            }
                        };
                    if irrefutable {
                        covered[tag] = true;
                    }
                }
                // Var/Tuple/bare-literal patterns are not supported as a
                // top-level enum match arm.
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
                    let Some(merged) = self.merge_branch_types(expected, &body_ty) else {
                        return Err(TypeError::at(
                            format!(
                                "match arms have different types: {} and {}",
                                expected, body_ty
                            ),
                            body.span(),
                        ));
                    };
                    result_ty = Some(merged);
                }
            }
        }

        // Exhaustiveness: every variant must be fully covered, or a wildcard
        // present. Nested variant and literal sub-patterns are refutable: they
        // cover only part of the outer variant's value space, so a fallback arm
        // is still required unless a later irrefutable pattern covers the same
        // top-level variant.
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

    /// Type-check a (possibly top-level) variant pattern `name(args...)` against
    /// the enum `enum_name`, binding identifiers found anywhere in `args`.
    /// Returns the matched variant's tag index plus whether this pattern fully
    /// covers that variant for exhaustiveness. A nested variant or literal
    /// sub-pattern is refutable unless it recursively covers the whole nested
    /// enum field, so the outer variant may need a later fallback arm.
    /// Callers are responsible for `pop_scope` on error (so bindings made before
    /// the failure are discarded).
    fn check_variant_pattern(
        &mut self,
        enum_name: &str,
        name: &str,
        args: &[Pattern],
        span: Span,
    ) -> Result<(usize, bool), TypeError> {
        let (owner, tag, fields) = self
            .enums
            .lookup_variant(name)
            .ok_or_else(|| TypeError::at(format!("unknown variant '{}' in match", name), span))?;
        if owner != enum_name {
            let owner = owner.to_string();
            return Err(TypeError::at(
                format!(
                    "variant '{}' belongs to enum {}, not {}",
                    name, owner, enum_name
                ),
                span,
            ));
        }
        if args.len() != fields.len() {
            let nfields = fields.len();
            return Err(TypeError::at(
                format!(
                    "variant '{}' binds {} fields but pattern has {}",
                    name,
                    nfields,
                    args.len()
                ),
                span,
            ));
        }
        // Resolve each payload field type before checking sub-patterns so a
        // nominal payload (a struct/enum named in the `defenum`, parsed as
        // `Type::Var`) becomes its concrete `Type::Struct`/`Type::Enum`. The
        // lowerer resolves these types the same way.
        let field_tys: Vec<Type> = fields.iter().map(|t| self.resolve_type(t)).collect();
        let mut irrefutable = true;
        for (arg, fty) in args.iter().zip(field_tys.iter()) {
            self.check_sub_pattern(arg, fty, span)?;
            if !self.sub_pattern_is_irrefutable(arg, fty) {
                irrefutable = false;
            }
        }
        Ok((tag, irrefutable))
    }

    /// Whether a checked sub-pattern covers every value of a payload field.
    /// Binding and `_` always do. A nested variant only does when the field enum
    /// has exactly one variant and that variant's own fields are all covered.
    /// Literal sub-patterns are always refutable.
    fn sub_pattern_is_irrefutable(&self, pat: &Pattern, fty: &Type) -> bool {
        match pat {
            Pattern::Binding(_) | Pattern::Wildcard => true,
            Pattern::Literal(_) => false,
            Pattern::Variant { name, args } => {
                let Type::Enum(enum_name) = fty else {
                    return false;
                };
                let Some(variants) = self.enums.variants(enum_name) else {
                    return false;
                };
                if variants.len() != 1 {
                    return false;
                }
                let Some((owner, _tag, fields)) = self.enums.lookup_variant(name) else {
                    return false;
                };
                if owner != enum_name || args.len() != fields.len() {
                    return false;
                }
                let field_tys: Vec<Type> = fields.iter().map(|t| self.resolve_type(t)).collect();
                args.iter()
                    .zip(field_tys.iter())
                    .all(|(arg, fty)| self.sub_pattern_is_irrefutable(arg, fty))
            }
            _ => false,
        }
    }

    /// Type-check a sub-pattern (a variant payload field) against its field
    /// type `fty`, binding any identifiers it introduces:
    /// - `Binding(x)` binds `x : fty` (irrefutable);
    /// - `Wildcard` ignores the field;
    /// - a nested `Variant` requires `fty` to be an enum and recurses;
    /// - a `Literal` requires `fty` to be the matching scalar (refutable).
    fn check_sub_pattern(
        &mut self,
        pat: &Pattern,
        fty: &Type,
        span: Span,
    ) -> Result<(), TypeError> {
        match pat {
            Pattern::Binding(name) => {
                self.bind(name.clone(), fty.clone());
                Ok(())
            }
            Pattern::Wildcard => Ok(()),
            Pattern::Variant { name, args } => match fty {
                Type::Enum(sub_enum) => {
                    self.check_variant_pattern(&sub_enum.clone(), name, args, span)?;
                    Ok(())
                }
                other => Err(TypeError::at(
                    format!(
                        "nested variant pattern '{}' requires an enum field, got {}",
                        name, other
                    ),
                    span,
                )),
            },
            Pattern::Literal(lit) => {
                let lit_ty = Self::literal_pattern_type(lit);
                let ok = if matches!(lit, Literal::Int(_)) {
                    fty.is_integer()
                } else {
                    self.types_equal(fty, &lit_ty)
                };
                if !ok {
                    return Err(TypeError::at(
                        format!(
                            "literal sub-pattern of type {} does not match field type {}",
                            lit_ty, fty
                        ),
                        span,
                    ));
                }
                Ok(())
            }
            other => Err(TypeError::at(
                format!("unsupported nested match pattern: {:?}", other),
                span,
            )),
        }
    }

    fn type_compatible(&self, expected: &Type, actual: &Type) -> bool {
        matches!(actual, Type::Never) || self.types_equal(expected, actual)
    }

    fn merge_branch_types(&self, a: &Type, b: &Type) -> Option<Type> {
        if matches!(a, Type::Never) {
            Some(b.clone())
        } else if matches!(b, Type::Never) || self.types_equal(a, b) {
            Some(a.clone())
        } else {
            None
        }
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

fn unsupported_global_aggregate_reason(
    ty: &Type,
    enums: &EnumRegistry,
    structs: &StructRegistry,
) -> Option<String> {
    let resolved = structs.resolve_type(&enums.resolve_type(ty));
    let mut seen_enums = HashSet::new();
    let mut seen_structs = HashSet::new();
    unsupported_global_aggregate_reason_inner(
        &resolved,
        true,
        enums,
        structs,
        &mut seen_enums,
        &mut seen_structs,
    )
}

fn unsupported_global_aggregate_reason_inner(
    ty: &Type,
    top_level: bool,
    enums: &EnumRegistry,
    structs: &StructRegistry,
    seen_enums: &mut HashSet<String>,
    seen_structs: &mut HashSet<String>,
) -> Option<String> {
    match ty {
        Type::Tuple(elems) => {
            if top_level {
                return Some(
                    "top-level tuple globals require by-value tuple ABI, which is not yet wired; \
                     wrap the value in a struct or enum"
                        .into(),
                );
            }
            for (idx, elem) in elems.iter().enumerate() {
                let elem = structs.resolve_type(&enums.resolve_type(elem));
                if let Some(reason) = unsupported_global_aggregate_reason_inner(
                    &elem,
                    false,
                    enums,
                    structs,
                    seen_enums,
                    seen_structs,
                ) {
                    return Some(format!("tuple element {} {}", idx, reason));
                }
            }
            None
        }
        Type::Array(_, _) => Some(
            "uses fixed-size array storage, which is inline and is not heap-promoted by \
             runtime global initializers yet"
                .into(),
        ),
        Type::Enum(name) => {
            if !seen_enums.insert(name.clone()) {
                return None;
            }
            let found = enums.variants(name).and_then(|variants| {
                for variant in variants {
                    for (idx, field) in variant.fields.iter().enumerate() {
                        let field = structs.resolve_type(&enums.resolve_type(field));
                        if let Some(reason) = unsupported_global_aggregate_reason_inner(
                            &field,
                            false,
                            enums,
                            structs,
                            seen_enums,
                            seen_structs,
                        ) {
                            return Some(format!(
                                "variant '{}' field {} {}",
                                variant.name, idx, reason
                            ));
                        }
                    }
                }
                None
            });
            seen_enums.remove(name);
            found
        }
        Type::Struct(name) => {
            if !seen_structs.insert(name.clone()) {
                return None;
            }
            let found = structs.fields(name).and_then(|fields| {
                for field in fields {
                    let field_ty = structs.resolve_type(&enums.resolve_type(&field.ty));
                    if let Some(reason) = unsupported_global_aggregate_reason_inner(
                        &field_ty,
                        false,
                        enums,
                        structs,
                        seen_enums,
                        seen_structs,
                    ) {
                        return Some(format!("field '{}' {}", field.name, reason));
                    }
                }
                None
            });
            seen_structs.remove(name);
            found
        }
        Type::DynArray(elem) => {
            let elem = structs.resolve_type(&enums.resolve_type(elem));
            if is_dyn_array_elem_supported(&elem) {
                None
            } else {
                Some(format!(
                    "dynamic-array globals require supported element types; element type {} \
                     is not yet supported",
                    elem
                ))
            }
        }
        _ => None,
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
    use crate::parser::{ReplItem, parse, parse_repl_item};

    fn repl_decl(src: &str) -> Decl {
        match parse_repl_item(src).unwrap() {
            ReplItem::Decl(decl) => decl,
            other => panic!("expected REPL declaration, got {:?}", other),
        }
    }

    fn repl_expr(src: &str) -> Expr {
        match parse_repl_item(src).unwrap() {
            ReplItem::Expr(expr) => expr,
            other => panic!("expected REPL expression, got {:?}", other),
        }
    }

    #[test]
    fn test_typecheck_basic() {
        let prog = parse("(define x : i64 42)").unwrap();
        let mut tc = TypeChecker::new();
        assert!(tc.check_program(&prog).is_ok());
    }

    #[test]
    fn test_typecheck_rejects_unsupported_type_kind_in_parameter() {
        let prog = parse("(define (f [T : type]) : i64 0)").unwrap();
        let mut tc = TypeChecker::new();
        let err = tc.check_program(&prog).unwrap_err();

        assert!(
            err.msg.contains("unsupported type kind 'type'"),
            "got: {}",
            err.msg
        );
        assert!(
            err.msg
                .contains("comptime type values are not implemented yet"),
            "got: {}",
            err.msg
        );
    }

    #[test]
    fn test_typecheck_rejects_unsupported_type_kind_in_definition() {
        let prog = parse("(define x : type 0)").unwrap();
        let mut tc = TypeChecker::new();
        let err = tc.check_program(&prog).unwrap_err();

        assert!(
            err.msg.contains("unsupported type kind 'type'"),
            "got: {}",
            err.msg
        );
    }

    #[test]
    fn test_typecheck_rejects_unsupported_type_kind_in_expression_type_position() {
        let prog = parse("(define (main) : i64 (ann 1 : type))").unwrap();
        let mut tc = TypeChecker::new();
        let err = tc.check_program(&prog).unwrap_err();

        assert!(
            err.msg.contains("unsupported type kind 'type'"),
            "got: {}",
            err.msg
        );
    }

    #[test]
    fn test_typecheck_unknown_nominal_type_is_distinct_from_type_kind() {
        let prog = parse("(define (f [x : Missing]) : i64 0)").unwrap();
        let mut tc = TypeChecker::new();
        let err = tc.check_program(&prog).unwrap_err();

        assert!(
            err.msg.contains("unknown type name 'Missing'"),
            "got: {}",
            err.msg
        );
        assert!(
            !err.msg.contains("unsupported type kind"),
            "got: {}",
            err.msg
        );
    }

    #[test]
    fn test_check_repl_expr_uses_session_decls() {
        let session = parse("(define answer : i64 41)").unwrap();
        let expr = repl_expr("(+ answer 1)");

        let ty = TypeChecker::check_repl_expr(&session.decls, &expr).unwrap();

        assert_eq!(ty, Type::I64);
    }

    #[test]
    fn test_check_repl_expr_error_does_not_mutate_session_decls() {
        let session = parse("(define answer : i64 41)").unwrap();
        let missing = repl_expr("(+ missing 1)");
        let err = TypeChecker::check_repl_expr(&session.decls, &missing).unwrap_err();
        assert!(
            err.msg.contains("unbound variable: missing"),
            "got: {}",
            err
        );
        assert_eq!(session.decls.len(), 1);

        let answer = repl_expr("answer");
        let ty = TypeChecker::check_repl_expr(&session.decls, &answer).unwrap();
        assert_eq!(ty, Type::I64);
    }

    #[test]
    fn test_check_repl_decl_uses_session_decls() {
        let session = parse("(define answer : i64 41)").unwrap();
        let candidate = repl_decl("(define next : i64 (+ answer 1))");

        assert!(TypeChecker::check_repl_decl(&session.decls, &candidate).is_ok());
    }

    #[test]
    fn test_check_repl_decl_detects_duplicate_names() {
        let session = parse("(define answer : i64 41)").unwrap();
        let candidate = repl_decl("(define answer : i64 42)");

        let err = TypeChecker::check_repl_decl(&session.decls, &candidate).unwrap_err();
        assert!(
            err.msg.contains("duplicate top-level name 'answer'"),
            "got: {}",
            err
        );
    }

    #[test]
    fn test_typecheck_cond_reuses_if_condition_rules() {
        let prog = parse("(define (f) : i64 (cond [1 2] [else 3]))").unwrap();
        let mut tc = TypeChecker::new();
        let err = tc.check_program(&prog).unwrap_err();
        assert!(
            err.msg.contains("if condition must be bool"),
            "got: {}",
            err
        );
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
    fn test_typecheck_argv_builtins() {
        let prog = parse(
            r#"
            (define (main) : i64
              (+ (arg-count) (string-length (arg 0))))
        "#,
        )
        .unwrap();
        let mut tc = TypeChecker::new();
        assert!(tc.check_program(&prog).is_ok());
    }

    #[test]
    fn test_typecheck_arg_index_must_be_i64() {
        let prog = parse(r#"(define (main) : String (arg "0"))"#).unwrap();
        let mut tc = TypeChecker::new();
        assert!(tc.check_program(&prog).is_err());
    }

    #[test]
    fn test_typecheck_arg_arity_checked() {
        let prog = parse(r#"(define (main) : String (arg 0 1))"#).unwrap();
        let mut tc = TypeChecker::new();
        assert!(tc.check_program(&prog).is_err());
    }

    #[test]
    fn test_typecheck_arg_count_arity_checked() {
        let prog = parse("(define (main) : i64 (arg-count 0))").unwrap();
        let mut tc = TypeChecker::new();
        assert!(tc.check_program(&prog).is_err());
    }

    #[test]
    fn test_typecheck_argv_builtins_can_be_shadowed() {
        let prog = parse(
            r#"
            (define (arg-count) : i64 9)
            (define (arg [n : i64]) : i64 n)
            (define (main) : i64 (+ (arg-count) (arg 1)))
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

    // ------------------------------------------------------------------
    // Duplicate top-level names — Issue #44
    // ------------------------------------------------------------------

    #[test]
    fn test_typecheck_duplicate_function_names_error() {
        let prog = concat_modules(
            "(define (foo [x : i64]) : i64 x)",
            "(define (foo [x : i64]) : i64 (+ x 1))",
        );
        let mut tc = TypeChecker::new();
        let err = tc.check_program(&prog).unwrap_err();
        assert!(
            err.msg.contains("duplicate top-level name 'foo'"),
            "err: {}",
            err
        );
    }

    #[test]
    fn test_typecheck_duplicate_define_and_function_error() {
        let prog = parse(
            r#"
            (define foo : i64 42)
            (define (foo [x : i64]) : i64 x)
            "#,
        )
        .unwrap();
        let mut tc = TypeChecker::new();
        let err = tc.check_program(&prog).unwrap_err();
        assert!(
            err.msg.contains("duplicate top-level name 'foo'"),
            "err: {}",
            err
        );
    }

    #[test]
    fn test_typecheck_duplicate_enum_variant_error() {
        let src = r#"
            (defenum A (Foo))
            (defenum B (Foo))
        "#;
        let prog = parse(src).unwrap();
        let mut tc = TypeChecker::new();
        let err = tc.check_program(&prog).unwrap_err();
        assert!(
            err.msg.contains("duplicate top-level name 'Foo'"),
            "err: {}",
            err
        );
    }

    #[test]
    fn test_typecheck_duplicate_enum_variant_across_modules_error() {
        let prog = concat_modules(
            "(defenum Imported (Shared))",
            "(import \"a.tl\")\n(defenum Local (Shared))",
        );
        let mut tc = TypeChecker::new();
        let err = tc.check_program(&prog).unwrap_err();
        assert!(
            err.msg.contains("duplicate top-level name 'Shared'"),
            "err: {}",
            err
        );
    }

    #[test]
    fn test_typecheck_duplicate_enum_type_name_error() {
        let src = r#"
            (defenum Shape (Circle))
            (defenum Shape (Square))
        "#;
        let prog = parse(src).unwrap();
        let mut tc = TypeChecker::new();
        let err = tc.check_program(&prog).unwrap_err();
        assert!(
            err.msg.contains("duplicate top-level type name 'Shape'"),
            "err: {}",
            err
        );
    }

    #[test]
    fn test_typecheck_duplicate_nominal_type_name_error() {
        let src = r#"
            (defenum Shape (Circle))
            (defstruct Shape (x i64))
        "#;
        let prog = parse(src).unwrap();
        let mut tc = TypeChecker::new();
        let err = tc.check_program(&prog).unwrap_err();
        assert!(
            err.msg.contains("duplicate top-level type name 'Shape'"),
            "err: {}",
            err
        );
    }

    #[test]
    fn test_typecheck_duplicate_struct_and_function_error() {
        let prog = parse(
            r#"
            (defstruct Point (x i64))
            (define (Point [x : i64]) : i64 x)
            "#,
        )
        .unwrap();
        let mut tc = TypeChecker::new();
        let err = tc.check_program(&prog).unwrap_err();
        assert!(
            err.msg.contains("duplicate top-level name 'Point'"),
            "err: {}",
            err
        );
    }

    #[test]
    fn test_typecheck_duplicate_extern_error() {
        let prog = parse(
            r#"
            (extern foo : (-> i64 i64))
            (extern foo : (-> bool bool))
            "#,
        )
        .unwrap();
        let mut tc = TypeChecker::new();
        let err = tc.check_program(&prog).unwrap_err();
        assert!(
            err.msg.contains("duplicate top-level name 'foo'"),
            "err: {}",
            err
        );
    }

    #[test]
    fn test_typecheck_no_duplicate_across_different_names_ok() {
        let prog = parse(
            r#"
            (defenum A (Foo))
            (defenum B (Bar))
            (define (baz [x : i64]) : i64 x)
            "#,
        )
        .unwrap();
        let mut tc = TypeChecker::new();
        assert!(tc.check_program(&prog).is_ok());
    }

    #[test]
    fn test_typecheck_enum_type_may_share_name_with_own_variant_ok() {
        // Type names and value names live in separate namespaces, so an enum
        // type may have a variant with the same name.
        let prog = parse(
            r#"
            (defenum Shape (Shape i64) (Circle))
            (define (make [x : i64]) : Shape (Shape x))
            "#,
        )
        .unwrap();
        let mut tc = TypeChecker::new();
        assert!(tc.check_program(&prog).is_ok());
    }

    #[test]
    fn test_typecheck_variant_collides_with_function_error() {
        let prog = parse(
            r#"
            (defenum A (Foo))
            (define (Foo [x : i64]) : i64 x)
            "#,
        )
        .unwrap();
        let mut tc = TypeChecker::new();
        let err = tc.check_program(&prog).unwrap_err();
        assert!(
            err.msg.contains("duplicate top-level name 'Foo'"),
            "err: {}",
            err
        );
    }

    #[test]
    fn test_typecheck_variant_collides_with_define_error() {
        let prog = parse(
            r#"
            (defenum A (Foo))
            (define Foo : i64 42)
            "#,
        )
        .unwrap();
        let mut tc = TypeChecker::new();
        let err = tc.check_program(&prog).unwrap_err();
        assert!(
            err.msg.contains("duplicate top-level name 'Foo'"),
            "err: {}",
            err
        );
    }

    #[test]
    fn test_typecheck_variant_collides_with_extern_error() {
        let prog = parse(
            r#"
            (defenum A (Foo))
            (extern Foo : (-> i64 i64))
            "#,
        )
        .unwrap();
        let mut tc = TypeChecker::new();
        let err = tc.check_program(&prog).unwrap_err();
        assert!(
            err.msg.contains("duplicate top-level name 'Foo'"),
            "err: {}",
            err
        );
    }

    #[test]
    fn test_typecheck_variant_collides_with_struct_constructor_error() {
        // Struct names are constructors in the value namespace, so they collide
        // with enum variants of the same name.
        let prog = parse(
            r#"
            (defenum A (Foo))
            (defstruct Foo (x i64))
            "#,
        )
        .unwrap();
        let mut tc = TypeChecker::new();
        let err = tc.check_program(&prog).unwrap_err();
        assert!(
            err.msg.contains("duplicate top-level name 'Foo'"),
            "err: {}",
            err
        );
    }

    #[test]
    fn test_typecheck_builtin_shadowing_not_duplicate() {
        // Built-ins are allowed to be shadowed by user-defined names.
        let prog = parse(
            r#"
            (define (print [x : i64]) : i64 (+ x 1))
            (define (main) : i64 (print 41))
            "#,
        )
        .unwrap();
        let mut tc = TypeChecker::new();
        assert!(tc.check_program(&prog).is_ok());
    }

    #[test]
    fn test_typecheck_noncapturing_lambda_ok() {
        let prog = parse(
            r#"
            (define (main) : i64
              ((lambda ([x : i64]) : i64 (+ x 1)) 41))
            "#,
        )
        .unwrap();
        let mut tc = TypeChecker::new();
        assert!(tc.check_program(&prog).is_ok());
    }

    #[test]
    fn test_typecheck_scalar_capturing_lambda_ok() {
        let prog = parse(
            r#"
            (define (main) : i64
              (let ([n : i64 10])
                ((lambda ([x : i64]) : i64 (+ x n)) 5)))
            "#,
        )
        .unwrap();
        let mut tc = TypeChecker::new();
        assert!(tc.check_program(&prog).is_ok());
    }

    #[test]
    fn test_typecheck_set_to_captured_lambda_name_rejected() {
        let prog = parse(
            r#"
            (define (main) : i64
              (let ([n : i64 10])
                (begin
                  ((lambda () : unit (set! n 11)))
                  n)))
            "#,
        )
        .unwrap();
        let mut tc = TypeChecker::new();
        let err = tc.check_program(&prog).unwrap_err();
        assert!(
            err.msg.contains("set! to captured variable 'n'"),
            "err: {}",
            err
        );
    }

    #[test]
    fn test_typecheck_aggregate_capture_rejected() {
        let prog = parse(
            r#"
            (define (main) : i64
              (let ([s : String "hello"]
                    [f : (-> String) (lambda () : String s)])
                (string-length (f))))
            "#,
        )
        .unwrap();
        let mut tc = TypeChecker::new();
        let err = tc.check_program(&prog).unwrap_err();
        assert!(
            err.msg
                .contains("capturing value 's' of type String is not yet supported"),
            "err: {}",
            err
        );
    }

    #[test]
    fn test_typecheck_aggregate_returning_lambdas_ok() {
        let prog = parse(
            r#"
            (defenum Box (BoxI i64))
            (defstruct Pair (x i64) (y i64))

            (define (main) : i64
              (let ([mk-string : (-> String) (lambda () : String "hello")]
                    [mk-enum : (-> Box) (lambda () : Box (BoxI 11))]
                    [mk-array : (-> (Array i64)) (lambda () : (Array i64) (make-array i64 13))]
                    [mk-struct : (-> Pair) (lambda () : Pair (Pair 1 13))])
                (+ (string-length (mk-string))
                   (+ (match (mk-enum) [(BoxI n) n])
                      (+ (array-length (mk-array))
                         (struct-get (mk-struct) y))))))
            "#,
        )
        .unwrap();
        let mut tc = TypeChecker::new();
        assert!(tc.check_program(&prog).is_ok());
    }

    #[test]
    fn test_typecheck_runtime_aggregate_globals_allowed() {
        let prog = parse(
            r#"
            (defenum MaybeI64 (Some i64) (None))
            (defstruct Pair (x i64) (y i64))
            (defstruct Nested (label String) (choice MaybeI64))

            (define greeting "hello")
            (define choice : MaybeI64 (Some 8))
            (define pair (Pair 10 11))
            (define cells : (Array i64) (make-array i64 3))
            (define nested : Nested (Nested "ok" (Some 3)))

            (define (main) : i64
              (+ (+ (+ (string-length greeting) (length cells))
                    (+ (struct-get pair x) (struct-get pair y)))
                 (+ (match choice [(Some n) n] [None 0])
                    (+ (string-length (struct-get nested label))
                       (match (struct-get nested choice) [(Some n) n] [None 0])))))
            "#,
        )
        .unwrap();
        let mut tc = TypeChecker::new();
        assert!(tc.check_program(&prog).is_ok());
    }

    #[test]
    fn test_typecheck_tuple_global_reports_precise_unsupported_aggregate() {
        let prog = parse(r#"(define bad : (Tuple String i64) (tuple "x" 1))"#).unwrap();
        let mut tc = TypeChecker::new();
        let err = tc.check_program(&prog).unwrap_err();
        assert!(
            err.msg
                .contains("unsupported aggregate type (Tuple String i64)"),
            "err: {}",
            err
        );
        assert!(err.msg.contains("top-level tuple globals"), "err: {}", err);
    }

    #[test]
    fn test_typecheck_nested_fixed_array_global_reports_precise_unsupported_aggregate() {
        let prog = parse(
            r#"
            (defstruct HasArray (items (Array i64 3)))
            (define bad : HasArray (HasArray (array 1 2 3)))
            "#,
        )
        .unwrap();
        let mut tc = TypeChecker::new();
        let err = tc.check_program(&prog).unwrap_err();
        assert!(
            err.msg.contains("unsupported aggregate type HasArray"),
            "err: {}",
            err
        );
        assert!(err.msg.contains("field 'items'"), "err: {}", err);
        assert!(err.msg.contains("fixed-size array storage"), "err: {}", err);
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

    #[test]
    fn test_typecheck_comptime_reserved_diagnostic() {
        use crate::diagnostic::format_diagnostic;

        let src = "(define (main) : i64 (comptime (+ 1 2)))";
        let prog = parse(src).unwrap();
        let mut tc = TypeChecker::new();
        let err = tc.check_program(&prog).unwrap_err();

        assert!(err.msg.contains("comptime"), "got: {}", err.msg);
        assert!(err.msg.contains("reserved"), "got: {}", err.msg);
        assert!(err.msg.contains("not supported"), "got: {}", err.msg);

        let rendered = format_diagnostic(&err.to_diagnostic(), src, "test.tl");
        assert!(rendered.contains("error[E0200]"), "got:\n{}", rendered);
        assert!(rendered.contains("--> test.tl:1:22"), "got:\n{}", rendered);
        assert!(
            rendered.contains(" 1 | (define (main) : i64 (comptime (+ 1 2)))"),
            "got:\n{}",
            rendered
        );
        assert!(
            rendered.contains("^^^^^^^^^^^^^^^^^^"),
            "got:\n{}",
            rendered
        );
        assert!(!err.msg.contains("unbound variable"), "got: {}", err.msg);
    }

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
    fn test_typecheck_bare_nullary_variant_pattern_is_variant() {
        let src = "\
            (defenum Color (Red) (Green))\n\
            (define (score [c : Color]) : i64 \
              (match c [Red 1] [Green 2]))";
        assert!(check(src).is_ok());
    }

    #[test]
    fn test_typecheck_bare_enum_pattern_identifier_is_not_catch_all() {
        let src = "\
            (defenum Color (Red) (Green))\n\
            (define (score [c : Color]) : i64 \
              (match c [other 1] [_ 0]))";
        let err = check(src).unwrap_err();
        assert!(
            err.msg.contains("unknown variant 'other' in match"),
            "err: {}",
            err
        );
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
    fn test_typecheck_nullary_variant_call_form_constructs() {
        // GAP (D): the zero-arg call form `(Nothing)` constructs the nullary
        // variant, equivalent to bare `Nothing` and consistent with payload
        // construction `(Circle 1)`. It type-checks to the enum type, so it can
        // be the scrutinee of a `match` over `Shape`.
        let src = format!(
            "{SHAPE}\n(define (n) : i64 \
               (match (Nothing) [(Circle r) r] [(Square w) w] [(Nothing) 0]))"
        );
        assert!(check(&src).is_ok());
    }

    #[test]
    fn test_typecheck_nullary_variant_call_form_with_args_is_arity_error() {
        // `(Nothing 1)` gives a nullary variant a payload it does not have: an
        // arity error, not a silently-ignored argument.
        let src = format!(
            "{SHAPE}\n(define (n) : i64 \
               (match (Nothing 1) [(Circle r) r] [(Square w) w] [(Nothing) 0]))"
        );
        assert!(check(&src).is_err());
    }

    #[test]
    fn test_typecheck_zero_arg_function_call_still_dispatches() {
        // Disambiguation: a genuine zero-arg `define`d function `(f)` is bound as
        // a `Type::Func` and still CALLS the function (the function arm takes
        // precedence). The nullary-variant construction path only triggers when
        // the head resolved to an enum type, which a function name never does.
        let src = "(define (answer) : i64 42)\n(define (main) : i64 (answer))";
        assert!(check(src).is_ok());
    }

    #[test]
    fn test_typecheck_nullary_variant_call_form_respects_shadowing_type() {
        // A local enum-typed value whose name happens to match a nullary variant
        // from a different enum must not be accepted as construction of that
        // variant. The variant owner must match the enum type of the resolved
        // head expression.
        let src = "\
            (defenum Shape (Nothing))\n\
            (defenum Other (OtherV))\n\
            (define (main [Nothing : Other]) : Other (Nothing))";
        assert!(check(src).is_err());
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

    // ------------------------------------------------------------------
    // Nested pattern matching — Issue #41
    // ------------------------------------------------------------------

    const SEXPR: &str = "(defenum Sexpr (SInt i64) (SSym String) (SNil) (SCons Sexpr Sexpr))";

    #[test]
    fn test_typecheck_nested_pattern_binds_nested_field_types() {
        // `(SCons (SSym op) rest)` binds `op : String` (from the nested SSym)
        // and `rest : Sexpr`. Using `op` where a String is required and `rest`
        // where a Sexpr is required type-checks.
        let src = format!(
            "{SEXPR}\n(define (op-len [s : Sexpr]) : i64 \
               (match s [(SCons (SSym op) rest) (string-length op)] [_ 0]))"
        );
        assert!(check(&src).is_ok(), "{:?}", check(&src));
    }

    #[test]
    fn test_typecheck_nested_pattern_binds_rest_as_enum() {
        // The flat binding `rest` in a nested pattern is a full `Sexpr`, usable
        // in a recursive call.
        let src = format!(
            "{SEXPR}\n(define (depth [s : Sexpr]) : i64 \
               (match s [(SCons (SSym op) rest) (+ 1 (depth rest))] [_ 0]))"
        );
        assert!(check(&src).is_ok(), "{:?}", check(&src));
    }

    #[test]
    fn test_typecheck_nested_pattern_wrong_nested_variant_type_is_err() {
        // A nested variant pattern must name a variant of the FIELD's enum. The
        // `SInt` field of `SCons` is a `Sexpr`, so `(SCons (SInt x) r)` is fine;
        // but using a String-only op on the bound int payload is rejected.
        let src = format!(
            "{SEXPR}\n(define (f [s : Sexpr]) : i64 \
               (match s [(SCons (SInt n) r) (string-length n)] [_ 0]))"
        );
        // `n : i64`, `string-length` wants a String → type error.
        assert!(check(&src).is_err());
    }

    #[test]
    fn test_typecheck_nested_variant_on_non_enum_field_is_err() {
        // A nested variant sub-pattern on a non-enum field (here `SInt`'s i64
        // payload) is rejected.
        let src = format!(
            "{SEXPR}\n(define (f [s : Sexpr]) : i64 \
               (match s [(SInt (SNil)) 1] [_ 0]))"
        );
        let err = check(&src).unwrap_err();
        assert!(
            err.msg.contains("requires an enum field"),
            "got: {}",
            err.msg
        );
    }

    #[test]
    fn test_typecheck_nested_literal_sub_pattern_ok() {
        // A scalar literal sub-pattern against a matching field type.
        let src = format!(
            "{SEXPR}\n(define (f [s : Sexpr]) : i64 \
               (match s [(SCons (SInt 0) r) 1] [_ 0]))"
        );
        assert!(check(&src).is_ok(), "{:?}", check(&src));
    }

    #[test]
    fn test_typecheck_nested_literal_sub_pattern_type_mismatch_is_err() {
        // A bool literal sub-pattern against an i64 field is a type error.
        let src = format!(
            "{SEXPR}\n(define (f [s : Sexpr]) : i64 \
               (match s [(SCons (SInt true) r) 1] [_ 0]))"
        );
        let err = check(&src).unwrap_err();
        assert!(
            err.msg.contains("does not match field type"),
            "got: {}",
            err.msg
        );
    }

    #[test]
    fn test_typecheck_nested_pattern_does_not_regress_flat_exhaustiveness() {
        // A flat match with no wildcard must still be proven exhaustive over all
        // variants (unchanged behaviour). Dropping `SCons` is an error.
        let src = format!(
            "{SEXPR}\n(define (f [s : Sexpr]) : i64 \
               (match s [(SInt n) n] [(SSym x) 0] [(SNil) 0]))"
        );
        let err = check(&src).unwrap_err();
        assert!(err.msg.contains("non-exhaustive"), "got: {}", err.msg);
    }

    #[test]
    fn test_typecheck_refutable_nested_pattern_does_not_cover_outer_variant() {
        // `(Outer (Left n))` covers only the `Left` subset of `Outer` values.
        // Without a fallback for `Outer (Right ...)`, lowering would have a
        // nested mismatch edge into the match merge with no value.
        let src = "(defenum Inner (Left i64) (Right i64))\n\
                   (defenum Outer (Outer Inner))\n\
                   (define (f [o : Outer]) : i64 \
                     (match o [(Outer (Left n)) n]))";
        let err = check(src).unwrap_err();
        assert!(err.msg.contains("non-exhaustive"), "got: {}", err.msg);
        assert!(err.msg.contains("Outer"), "got: {}", err.msg);
    }

    #[test]
    fn test_typecheck_nested_pattern_with_same_variant_fallback_is_exhaustive() {
        // A later irrefutable arm for the same top-level variant covers the
        // nested mismatch path.
        let src = "(defenum Inner (Left i64) (Right i64))\n\
                   (defenum Outer (Outer Inner))\n\
                   (define (f [o : Outer]) : i64 \
                     (match o [(Outer (Left n)) n] [(Outer _) 0]))";
        assert!(check(src).is_ok(), "{:?}", check(src));
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
    fn test_typecheck_extern_enum_signatures_are_accepted() {
        let src = format!(
            "{SHAPE}\n\
             (extern foreign_shape : (-> Shape Shape))\n\
             (extern foreign_pick : (-> (Array Shape) Shape))\n\
             (define (roundtrip [s : Shape]) : Shape (foreign_shape s))\n\
             (define (pick [xs : (Array Shape)]) : Shape (foreign_pick xs))"
        );
        assert!(check(&src).is_ok(), "{:?}", check(&src));
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
    fn test_typecheck_monomorphic_maybe_requires_absence_arm() {
        let src = r#"
            (defenum MaybeI64
              (NoneI64)
              (SomeI64 i64))
            (define (value [m : MaybeI64]) : i64
              (match m
                [(SomeI64 v) v]))
        "#;
        let err = check(src).unwrap_err();
        assert!(
            err.msg.contains("missing variant(s) NoneI64"),
            "got: {}",
            err.msg
        );
    }

    #[test]
    fn test_typecheck_monomorphic_result_requires_error_arm() {
        let src = r#"
            (defenum ResultI64
              (OkI64 i64)
              (ErrI64 String))
            (define (value [r : ResultI64]) : i64
              (match r
                [(OkI64 v) v]))
        "#;
        let err = check(src).unwrap_err();
        assert!(
            err.msg.contains("missing variant(s) ErrI64"),
            "got: {}",
            err.msg
        );
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
    fn test_typecheck_match_string_literals_well_typed() {
        let src = r#"(define (classify [s : String]) : i64
                       (match s ["if" 10] ["let" 20] [_ 0]))"#;
        assert!(check(src).is_ok());
    }

    #[test]
    fn test_typecheck_match_string_literals_require_wildcard() {
        let src = r#"(define (classify [s : String]) : i64 (match s ["if" 10]))"#;
        let err = check(src).unwrap_err();
        assert!(err.msg.contains("non-exhaustive"), "got: {}", err.msg);
    }

    #[test]
    fn test_typecheck_nested_string_literal_pattern() {
        let src = r#"
            (defenum Token (TIdent String) (TEnd))
            (define (classify [t : Token]) : i64
              (match t
                [(TIdent "if") 10]
                [(TIdent _) 1]
                [(TEnd) 0]))
        "#;
        assert!(check(src).is_ok());
    }

    #[test]
    fn test_typecheck_match_bool_literals_well_typed() {
        let src = "(define (f [b : bool]) : i64 (match b [true 1] [false 0]))";
        assert!(check(src).is_ok());
    }

    #[test]
    fn test_typecheck_match_bool_literal_single_arm_non_exhaustive_is_err() {
        let src = "(define (f [b : bool]) : i64 (match b [true 1]))";
        let err = check(src).unwrap_err();
        assert!(err.msg.contains("non-exhaustive"), "got: {}", err.msg);
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
    fn test_typecheck_string_global_is_accepted() {
        // Runtime global initializers use the hidden-function return path, so
        // string literal storage is heap-promoted instead of dangling.
        let src = r#"(define greeting "hello")"#;
        assert!(check(src).is_ok());
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

    #[test]
    fn test_typecheck_read_file_yields_string() {
        let src = r#"(define (f) : String (read-file "input.tl"))"#;
        assert!(check(src).is_ok());
    }

    #[test]
    fn test_typecheck_read_file_requires_string_path() {
        let src = "(define (f) : String (read-file 42))";
        assert!(check(src).is_err());
    }

    #[test]
    fn test_typecheck_read_file_arity_checked() {
        let src = r#"(define (f) : String (read-file "a" "b"))"#;
        assert!(check(src).is_err());
    }

    #[test]
    fn test_typecheck_read_file_result_is_not_i64() {
        let src = r#"(define (f) : i64 (read-file "input.tl"))"#;
        assert!(check(src).is_err());
    }

    #[test]
    fn test_typecheck_read_file_builtin_can_be_shadowed() {
        let src = r#"
            (define (read-file [n : i64]) : i64 n)
            (define (main) : i64 (read-file 7))
        "#;
        assert!(check(src).is_ok());
    }

    #[test]
    fn test_typecheck_write_file_yields_unit() {
        let src = r#"(define (f) : unit (write-file "out.s" "hello"))"#;
        assert!(check(src).is_ok());
    }

    #[test]
    fn test_typecheck_write_file_requires_string_path() {
        let src = r#"(define (f) : unit (write-file 42 "hello"))"#;
        assert!(check(src).is_err());
    }

    #[test]
    fn test_typecheck_write_file_requires_string_contents() {
        let src = r#"(define (f) : unit (write-file "out.s" 42))"#;
        assert!(check(src).is_err());
    }

    #[test]
    fn test_typecheck_write_file_arity_checked() {
        let src = r#"(define (f) : unit (write-file "out.s"))"#;
        assert!(check(src).is_err());
    }

    #[test]
    fn test_typecheck_write_file_result_is_not_i64() {
        let src = r#"(define (f) : i64 (write-file "out.s" "hello"))"#;
        assert!(check(src).is_err());
    }

    #[test]
    fn test_typecheck_write_file_builtin_can_be_shadowed() {
        let src = r#"
            (define (write-file [n : i64]) : i64 n)
            (define (main) : i64 (write-file 7))
        "#;
        assert!(check(src).is_ok());
    }

    #[test]
    fn test_typecheck_file_exists_yields_bool() {
        let src = r#"(define (f) : bool (file-exists? "input.tl"))"#;
        assert!(check(src).is_ok());
    }

    #[test]
    fn test_typecheck_file_exists_requires_string_path() {
        let src = "(define (f) : bool (file-exists? 42))";
        assert!(check(src).is_err());
    }

    #[test]
    fn test_typecheck_file_exists_arity_checked() {
        let src = r#"(define (f) : bool (file-exists? "a" "b"))"#;
        assert!(check(src).is_err());
    }

    #[test]
    fn test_typecheck_file_exists_result_is_not_i64() {
        let src = r#"(define (f) : i64 (file-exists? "input.tl"))"#;
        assert!(check(src).is_err());
    }

    #[test]
    fn test_typecheck_file_exists_builtin_can_be_shadowed() {
        let src = r#"
            (define (file-exists? [n : i64]) : i64 n)
            (define (main) : i64 (file-exists? 7))
        "#;
        assert!(check(src).is_ok());
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
    // string-append / string-concat — `(-> String String String)` (refs #13/#27)
    // ------------------------------------------------------------------

    #[test]
    fn test_typecheck_string_append_yields_string() {
        // `(string-append a b)` : `(-> String String String)`. Concatenating two
        // String parameters and returning the result type-checks as a String.
        let src = "(define (f [a : String] [b : String]) : String (string-append a b))";
        assert!(check(src).is_ok());
    }

    #[test]
    fn test_typecheck_string_concat_alias_yields_string() {
        // `string-concat` is the alias of `string-append` with identical type.
        let src = "(define (f [a : String] [b : String]) : String (string-concat a b))";
        assert!(check(src).is_ok());
    }

    #[test]
    fn test_typecheck_string_append_on_literals() {
        // Two String literals concatenate fine.
        let src = r#"(define (f) : String (string-append "foo" "bar"))"#;
        assert!(check(src).is_ok());
    }

    #[test]
    fn test_typecheck_string_append_requires_string_first_arg() {
        // The first argument must be a String, not an i64.
        let src = r#"(define (f) : String (string-append 42 "bar"))"#;
        assert!(check(src).is_err());
    }

    #[test]
    fn test_typecheck_string_append_requires_string_second_arg() {
        // The second argument must be a String, not an i64.
        let src = r#"(define (f) : String (string-append "foo" 42))"#;
        assert!(check(src).is_err());
    }

    #[test]
    fn test_typecheck_string_append_arity_checked() {
        // `string-append` is binary; one argument is an arity error.
        let src = r#"(define (f) : String (string-append "foo"))"#;
        let err = check(src).unwrap_err();
        assert!(err.msg.contains("arguments"), "got: {}", err.msg);
    }

    #[test]
    fn test_typecheck_string_append_result_is_not_i64() {
        // The result is a String, not an i64; using it where an i64 is required
        // (the function's declared return) is a type error.
        let src = r#"(define (f) : i64 (string-append "foo" "bar"))"#;
        assert!(check(src).is_err());
    }

    // ------------------------------------------------------------------
    // panic / error — Issue #45
    // ------------------------------------------------------------------

    #[test]
    fn test_typecheck_panic_satisfies_unit_return() {
        // Builtin `panic` has internal never type and satisfies an expected
        // unit return.
        let src = r#"(define (f) : unit (panic "bad input"))"#;
        assert!(check(src).is_ok());
    }

    #[test]
    fn test_typecheck_error_alias_satisfies_unit_return() {
        // `error` is the alias of builtin `panic` with identical never result.
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
    fn test_typecheck_panic_satisfies_i64_return() {
        let src = r#"(define (f) : i64 (panic "boom"))"#;
        assert!(check(src).is_ok());
    }

    #[test]
    fn test_typecheck_panic_branch_satisfies_i64() {
        let src = r#"(define (f [ok : bool]) : i64 (if ok 1 (panic "bad")))"#;
        assert!(check(src).is_ok());
    }

    #[test]
    fn test_typecheck_begin_panic_satisfies_i64() {
        let src = r#"(define (f) : i64 (begin (panic "boom")))"#;
        assert!(check(src).is_ok());
    }

    #[test]
    fn test_typecheck_panic_argument_satisfies_expected_type() {
        let src = r#"
            (define (takes [n : i64]) : i64 n)
            (define (f) : i64 (takes (panic "boom")))
        "#;
        assert!(check(src).is_ok());
    }

    #[test]
    fn test_typecheck_scalar_match_panic_arm_satisfies_i64() {
        let src = r#"
            (define (f [n : i64]) : i64
              (match n
                [0 (panic "zero")]
                [_ 1]))
        "#;
        assert!(check(src).is_ok());
    }

    #[test]
    fn test_typecheck_enum_match_panic_arm_satisfies_i64() {
        let src = r#"
            (defenum MaybeInt (Some i64) (None))
            (define (f [m : MaybeInt]) : i64
              (match m
                [(Some n) n]
                [None (error "missing")]))
        "#;
        assert!(check(src).is_ok());
    }

    #[test]
    fn test_typecheck_user_defined_panic_keeps_declared_return_type() {
        let src = r#"
            (define (panic [msg : String]) : unit unit)
            (define (f) : i64 (panic "boom"))
        "#;
        assert!(check(src).is_err());
    }

    #[test]
    fn test_typecheck_panic_with_dummy_value_in_non_unit_context() {
        // The old dummy-value style remains accepted, though builtin panic no
        // longer requires it in non-unit contexts.
        let src = r#"(define (f) : i64 (begin (panic "boom") 0))"#;
        assert!(check(src).is_ok());
    }

    #[test]
    fn test_typecheck_print_string_is_unit() {
        // `(print-string s)` : `(-> String unit)` — a string-literal argument
        // yields unit, so it type-checks as the body of a unit-returning fn.
        let src = r#"(define (f) : unit (print-string "hello"))"#;
        assert!(check(src).is_ok());
    }

    #[test]
    fn test_typecheck_print_str_alias_is_unit() {
        // `print-str` is the alias of `print-string` with identical
        // `(-> String unit)` type.
        let src = r#"(define (f) : unit (print-str "hello"))"#;
        assert!(check(src).is_ok());
    }

    #[test]
    fn test_typecheck_print_string_on_param() {
        // A String *parameter* prints fine (the caller owns the storage).
        let src = "(define (f [s : String]) : unit (print-string s))";
        assert!(check(src).is_ok());
    }

    #[test]
    fn test_typecheck_print_string_arg_type_checked() {
        // The argument must be a String; an i64 operand is rejected.
        let src = "(define (f) : unit (print-string 42))";
        assert!(check(src).is_err());
    }

    #[test]
    fn test_typecheck_print_string_arity_checked() {
        // `print-string` is unary; a second argument is an arity error.
        let src = r#"(define (f) : unit (print-string "a" "b"))"#;
        assert!(check(src).is_err());
    }

    #[test]
    fn test_typecheck_print_string_result_not_i64() {
        // The result is unit, not i64 — using it where i64 is expected fails.
        let src = r#"(define (f) : i64 (print-string "hi"))"#;
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
    fn test_typecheck_struct_global_is_accepted() {
        // Runtime global initializers use the hidden-function return path, so
        // struct constructor storage is heap-promoted instead of dangling.
        let src = format!("{POINT}\n(define origin (Point 0 0))");
        assert!(check(&src).is_ok());
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

    // ------------------------------------------------------------------
    // SPMD foreach — Issue #343
    // ------------------------------------------------------------------

    #[test]
    fn test_typecheck_foreach_well_typed() {
        let src = "(define (f [a : (Array i64)] [b : (Array i64)] \
                      [out : (Array i64)] [n : i64]) : unit \
               (foreach ([i : i64 0 n]) \
                 (array-set! out i (+ (array-ref a i) (array-ref b i)))))";
        assert!(check(src).is_ok(), "{:?}", check(src));
    }

    #[test]
    fn test_typecheck_foreach_index_type_must_be_integer() {
        let src = "(define (f [n : i64]) : unit (foreach ([i : bool 0 n]) unit))";
        let err = check(src).unwrap_err();
        assert!(
            err.msg.contains("foreach index type must be an integer"),
            "got: {}",
            err.msg
        );
    }

    #[test]
    fn test_typecheck_foreach_start_must_be_integer() {
        let src = "(define (f [n : i64]) : unit (foreach ([i : i64 true n]) unit))";
        let err = check(src).unwrap_err();
        assert!(
            err.msg.contains("start expression must be an integer"),
            "got: {}",
            err.msg
        );
    }

    #[test]
    fn test_typecheck_foreach_end_must_be_integer() {
        let src = "(define (f [n : i64]) : unit (foreach ([i : i64 0 true]) unit))";
        let err = check(src).unwrap_err();
        assert!(
            err.msg.contains("end expression must be an integer"),
            "got: {}",
            err.msg
        );
    }

    #[test]
    fn test_typecheck_foreach_body_must_be_unit() {
        let src = "(define (f [n : i64]) : unit (foreach ([i : i64 0 n]) i))";
        let err = check(src).unwrap_err();
        assert!(
            err.msg.contains("foreach body must have type unit"),
            "got: {}",
            err.msg
        );
    }

    #[test]
    fn test_typecheck_foreach_result_is_unit() {
        // The overall foreach expression has type unit, so using it where i64
        // is expected is rejected.
        let src = "(define (f [n : i64]) : i64 (foreach ([i : i64 0 n]) (print i)))";
        let err = check(src).unwrap_err();
        assert!(err.msg.contains("return type mismatch"), "got: {}", err.msg);
    }

    #[test]
    fn test_typecheck_foreach_index_in_scope_in_body() {
        // The index binding is visible in the body.
        let src = "(define (f [n : i64]) : unit (foreach ([i : i64 0 n]) (print i)))";
        assert!(check(src).is_ok());
    }

    #[test]
    fn test_typecheck_foreach_body_can_use_let_bindings() {
        let src = "(define (f [n : i64]) : unit \
                     (foreach ([i : i64 0 n]) \
                       (let ([x : i64 (+ i 1)]) unit)))";
        assert!(check(src).is_ok());
    }

    #[test]
    fn test_typecheck_foreach_nested_expressions_as_bounds() {
        // Start/end can be arbitrary integer expressions.
        let src = "(define (f [a : i64] [b : i64]) : unit \
                     (foreach ([i : i64 (+ a 1) (- b 1)]) unit))";
        assert!(check(src).is_ok());
    }

    #[test]
    fn test_typecheck_foreach_body_array_set_over_dynamic_array_ok() {
        // Using dynamic-array operations in the foreach body is the primary use case.
        let src = "(define (f [xs : (Array i64)] [n : i64]) : unit \
                     (foreach ([i : i64 0 n]) \
                       (array-set! xs i (+ (array-ref xs i) 1))))";
        assert!(check(src).is_ok());
    }
}
