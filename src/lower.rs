use crate::ast;
use crate::ir::*;
use crate::types::{
    DYN_ARRAY_FAT_SIZE, DYN_ARRAY_LEN_OFFSET, DYN_ARRAY_PTR_OFFSET, STRING_FAT_SIZE,
    STRING_LEN_OFFSET, STRING_PTR_OFFSET, Type,
};
use std::collections::{HashMap, HashSet};

/// Lowers a typed AST program into IR.
pub fn lower_program(prog: &ast::Program) -> Program {
    let mut lowerer = ProgramLowerer::new();
    lowerer.lower(prog)
}

struct ProgramLowerer {
    functions: Vec<Function>,
    globals: Vec<(String, Type, Option<Value>)>,
    externs: Vec<(String, Type)>,
    global_types: HashMap<String, Type>,
    function_types: HashMap<String, Type>,
    enums: ast::EnumRegistry,
    structs: ast::StructRegistry,
}

impl ProgramLowerer {
    fn new() -> Self {
        ProgramLowerer {
            functions: Vec::new(),
            globals: Vec::new(),
            externs: Vec::new(),
            global_types: HashMap::new(),
            function_types: HashMap::new(),
            enums: ast::EnumRegistry::default(),
            structs: ast::StructRegistry::default(),
        }
    }

    /// Resolve a parsed type so any `Type::Var` naming a declared enum or struct
    /// becomes the nominal `Type::Enum`/`Type::Struct`. Chains both registries.
    fn resolve_type(&self, ty: &Type) -> Type {
        self.structs.resolve_type(&self.enums.resolve_type(ty))
    }

    fn lower(&mut self, prog: &ast::Program) -> Program {
        self.enums = ast::EnumRegistry::from_program(prog);
        self.structs = ast::StructRegistry::from_program(prog);

        for decl in &prog.decls {
            match decl {
                ast::Decl::DefFn {
                    name, params, ret, ..
                } => {
                    self.function_types.insert(
                        name.clone(),
                        Type::Func(
                            params.iter().map(|(_, ty)| self.resolve_type(ty)).collect(),
                            Box::new(self.resolve_type(ret)),
                        ),
                    );
                }
                ast::Decl::Extern { name, ty } => {
                    self.function_types
                        .insert(name.clone(), self.resolve_type(ty));
                }
                ast::Decl::Def { name, ty, value } => {
                    let val_ty = ty
                        .as_ref()
                        .map(|ty| self.resolve_type(ty))
                        .unwrap_or_else(|| infer_literal_type(value));
                    self.global_types.insert(name.clone(), val_ty);
                }
                // A struct constructor `Name : (-> field-tys... Name)` is bound
                // as a callable so a construction `(Name v..)` lowers through the
                // struct path in `lower_call` (the head names a known struct).
                ast::Decl::DefStruct { name, fields } => {
                    let field_tys: Vec<Type> =
                        fields.iter().map(|f| self.resolve_type(&f.ty)).collect();
                    self.function_types.insert(
                        name.clone(),
                        Type::Func(field_tys, Box::new(Type::Struct(name.clone()))),
                    );
                }
                ast::Decl::DefEnum { .. } => {}
                // Imports are stripped by the loader before lowering; defensive.
                ast::Decl::Import(_) => {}
            }
        }

        for decl in &prog.decls {
            match decl {
                ast::Decl::Def { name, ty, value } => {
                    let val_ty = ty.clone().unwrap_or_else(|| infer_literal_type(value));
                    // Lower the global initializer as an anonymous function
                    let fn_lowerer = FnLowerer::new(
                        "__global_init",
                        &[],
                        &val_ty,
                        &self.function_types,
                        &self.global_types,
                        &self.enums,
                        &self.structs,
                    );
                    let (_func, _result_var) = fn_lowerer.lower_expr_to_fn(value, &val_ty);

                    // Replace the generated function name with a proper init approach
                    // For simplicity, just store the constant if possible
                    let init_value = extract_const(value);
                    self.globals.push((name.clone(), val_ty, init_value));
                }
                ast::Decl::DefFn {
                    name,
                    params,
                    ret,
                    body,
                } => {
                    let params: Vec<(String, Type)> = params
                        .iter()
                        .map(|(n, t)| (n.clone(), self.resolve_type(t)))
                        .collect();
                    let ret = self.resolve_type(ret);
                    let func = self.lower_function(name, &params, &ret, body);
                    self.functions.push(func);
                }
                ast::Decl::Extern { name, ty } => {
                    self.externs.push((name.clone(), self.resolve_type(ty)));
                }
                ast::Decl::DefEnum { .. } => {}
                // Struct decls carry no runtime value; the constructor is bound
                // above and lowered at its use sites.
                ast::Decl::DefStruct { .. } => {}
                // Imports are stripped by the loader before lowering; defensive.
                ast::Decl::Import(_) => {}
            }
        }

        Program {
            functions: self.functions.clone(),
            globals: self.globals.clone(),
            externs: self.externs.clone(),
        }
    }

    fn lower_function(
        &mut self,
        name: &str,
        params: &[(String, Type)],
        ret: &Type,
        body: &ast::Expr,
    ) -> Function {
        let fn_lowerer = FnLowerer::new(
            name,
            params,
            ret,
            &self.function_types,
            &self.global_types,
            &self.enums,
            &self.structs,
        );
        fn_lowerer.lower_body(body, ret)
    }
}

/// Infers the type of a literal expression for use in global initializers.
fn infer_literal_type(expr: &ast::Expr) -> Type {
    match expr.unspan() {
        ast::Expr::Literal(ast::Literal::Int(_)) => Type::I64,
        ast::Expr::Literal(ast::Literal::Float(_)) => Type::F64,
        ast::Expr::Literal(ast::Literal::Bool(_)) => Type::Bool,
        ast::Expr::Literal(ast::Literal::Char(_)) => Type::Char,
        ast::Expr::Literal(ast::Literal::String(_)) => Type::String,
        ast::Expr::Literal(ast::Literal::Unit) => Type::Unit,
        _ => Type::Unit,
    }
}

/// Extracts an IR Value from a constant AST expression, if possible.
fn extract_const(expr: &ast::Expr) -> Option<Value> {
    match expr.unspan() {
        ast::Expr::Literal(ast::Literal::Int(n)) => Some(Value::ConstI64(*n)),
        ast::Expr::Literal(ast::Literal::Float(n)) => Some(Value::ConstF64(*n)),
        ast::Expr::Literal(ast::Literal::Bool(b)) => Some(Value::ConstBool(*b)),
        ast::Expr::Literal(ast::Literal::Char(c)) => Some(Value::ConstI8(*c as i8)),
        ast::Expr::Literal(ast::Literal::Unit) => Some(Value::ConstUnit),
        ast::Expr::Ann { expr, .. } => extract_const(expr),
        ast::Expr::Cast { expr, ty } => extract_const_cast(expr, ty),
        _ => None,
    }
}

fn extract_const_cast(expr: &ast::Expr, to_ty: &Type) -> Option<Value> {
    let value = extract_const(expr)?;
    let value = match value {
        Value::ConstI64(n) => n as i128,
        Value::ConstI32(n) => n as i128,
        Value::ConstI8(n) => n as i128,
        _ => return None,
    };

    match to_ty {
        Type::I64 => Some(Value::ConstI64(value as i64)),
        Type::U64 => Some(Value::ConstI64(value as u64 as i64)),
        Type::I32 => Some(Value::ConstI32(value as i32)),
        Type::U32 => Some(Value::ConstI32(value as u32 as i32)),
        Type::I16 => Some(Value::ConstI64(value as i16 as i64)),
        Type::U16 => Some(Value::ConstI64(value as u16 as i64)),
        Type::I8 => Some(Value::ConstI8(value as i8)),
        Type::U8 | Type::Char => Some(Value::ConstI8(value as u8 as i8)),
        _ => None,
    }
}

struct FnLowerer {
    name: String,
    builder: IrBuilder,
    vars: HashMap<String, VarId>,
    /// Real type of every IR variable we create (params, locals, temporaries).
    /// This lets `value_type` recover the true width of a `Value::Var` instead
    /// of defaulting to `i64`, which is essential for width-correct codegen.
    var_types: HashMap<VarId, Type>,
    global_types: HashMap<String, Type>,
    function_types: HashMap<String, Type>,
    enums: ast::EnumRegistry,
    structs: ast::StructRegistry,
    params: Vec<(VarId, Type)>,
    locals: Vec<(VarId, Type)>,
    /// The enclosing function's (resolved) return type. Drives heap promotion:
    /// an aggregate constructor is heap-allocated only when a value of its kind
    /// can reach this return type (see `type_kind_escapes_via_return`).
    ret: Type,
}

/// The kind of escaping aggregate whose constructor storage may be
/// heap-promoted so the value can be returned without dangling.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum AggKind {
    Enum,
    String,
    DynArray,
    Struct,
}

/// Whether a value of aggregate `kind` can escape the current function via its
/// `return` — i.e. whether the (resolved) return type `ret` is, or structurally
/// nests, that aggregate kind. Returned enum types are expanded through the
/// registry, so payload aggregates are promoted too: returning `(Box "hi")`
/// must heap-promote both the outer enum storage and the inner string fat value.
/// This is the conservative, sound escape rule used to decide heap promotion of
/// constructor storage:
///
///   * SOUND: a frame-allocated aggregate can never reach a `Return` whose type
///     does not contain that aggregate kind, so leaving such constructors on the
///     frame can never return a dangling pointer. We only ever heap-promote when
///     the return type *can* carry the kind out of the frame.
///   * SELECTIVE: a function returning `i64` keeps all its local aggregates on
///     the frame; even a function returning `String` keeps its local *enum*
///     constructors on the frame (different kind). The conservativeness is that
///     within a function that *does* return a given kind, *all* constructors of
///     that kind are promoted, including ones that happen not to escape.
///
/// Nesting (`Tuple`/`Array`/`DynArray` and enum variant fields) is matched so a
/// value returned inside an aggregate is also promoted.
fn type_kind_escapes_via_return(
    ret: &Type,
    kind: AggKind,
    enums: &ast::EnumRegistry,
    structs: &ast::StructRegistry,
) -> bool {
    let mut seen_enums = HashSet::new();
    let mut seen_structs = HashSet::new();
    type_kind_escapes_via_return_inner(
        ret,
        kind,
        enums,
        structs,
        &mut seen_enums,
        &mut seen_structs,
    )
}

fn type_kind_escapes_via_return_inner(
    ty: &Type,
    kind: AggKind,
    enums: &ast::EnumRegistry,
    structs: &ast::StructRegistry,
    seen_enums: &mut HashSet<String>,
    seen_structs: &mut HashSet<String>,
) -> bool {
    match ty {
        Type::Enum(name) => {
            if kind == AggKind::Enum {
                return true;
            }
            if !seen_enums.insert(name.clone()) {
                return false;
            }
            let found = enums.variants(name).is_some_and(|variants| {
                variants.iter().any(|variant| {
                    variant.fields.iter().any(|field| {
                        let field = structs.resolve_type(&enums.resolve_type(field));
                        type_kind_escapes_via_return_inner(
                            &field,
                            kind,
                            enums,
                            structs,
                            seen_enums,
                            seen_structs,
                        )
                    })
                })
            });
            seen_enums.remove(name);
            found
        }
        Type::Struct(name) => {
            if kind == AggKind::Struct {
                return true;
            }
            if !seen_structs.insert(name.clone()) {
                return false;
            }
            let found = structs.fields(name).is_some_and(|fields| {
                fields.iter().any(|field| {
                    let field = structs.resolve_type(&enums.resolve_type(&field.ty));
                    type_kind_escapes_via_return_inner(
                        &field,
                        kind,
                        enums,
                        structs,
                        seen_enums,
                        seen_structs,
                    )
                })
            });
            seen_structs.remove(name);
            found
        }
        Type::String => kind == AggKind::String,
        Type::DynArray(elem) => {
            kind == AggKind::DynArray
                || type_kind_escapes_via_return_inner(
                    elem,
                    kind,
                    enums,
                    structs,
                    seen_enums,
                    seen_structs,
                )
        }
        Type::Tuple(elems) => elems.iter().any(|elem| {
            type_kind_escapes_via_return_inner(elem, kind, enums, structs, seen_enums, seen_structs)
        }),
        Type::Array(elem, _) => {
            type_kind_escapes_via_return_inner(elem, kind, enums, structs, seen_enums, seen_structs)
        }
        Type::Func(_, _) => false,
        _ => false,
    }
}

impl FnLowerer {
    fn new(
        name: &str,
        params: &[(String, Type)],
        ret: &Type,
        function_types: &HashMap<String, Type>,
        global_types: &HashMap<String, Type>,
        enums: &ast::EnumRegistry,
        structs: &ast::StructRegistry,
    ) -> Self {
        let mut builder = IrBuilder::new("entry");
        let mut vars = HashMap::new();
        let mut var_types = HashMap::new();
        let mut ir_params = Vec::new();

        for (param_name, param_ty) in params {
            let var = builder.fresh_var();
            builder.emit(Instruction::Alloc {
                var,
                ty: param_ty.clone(),
            });
            ir_params.push((var, param_ty.clone()));
            vars.insert(param_name.clone(), var);
            var_types.insert(var, param_ty.clone());
        }

        FnLowerer {
            name: name.to_string(),
            builder,
            vars,
            var_types,
            global_types: global_types.clone(),
            function_types: function_types.clone(),
            enums: enums.clone(),
            structs: structs.clone(),
            params: ir_params,
            locals: Vec::new(),
            ret: ret.clone(),
        }
    }

    /// Resolve a parsed type so any `Type::Var` naming a declared enum or struct
    /// becomes the nominal `Type::Enum`/`Type::Struct`. Chains both registries.
    fn resolve_type(&self, ty: &Type) -> Type {
        self.structs.resolve_type(&self.enums.resolve_type(ty))
    }

    /// Lower a function body and produce a complete IR Function.
    fn lower_body(mut self, body: &ast::Expr, ret_ty: &Type) -> Function {
        let result = self.lower_expr(body);
        if *ret_ty == Type::Unit {
            self.builder.emit(Instruction::Return(None));
        } else {
            self.builder.emit(Instruction::Return(Some(result)));
        }

        let blocks = self.builder.build();
        Function {
            name: self.name,
            params: self.params,
            ret: ret_ty.clone(),
            locals: self.locals,
            blocks,
            entry: "entry".into(),
        }
    }

    /// Lower an expression into a fresh IR variable holding its result.
    fn lower_expr(&mut self, expr: &ast::Expr) -> Value {
        match expr.unspan() {
            // A string literal constructs an inline fat `{ ptr, len }` value and
            // yields a pointer to it (the runtime representation of a string).
            ast::Expr::Literal(ast::Literal::String(s)) => self.lower_string_literal(s),
            ast::Expr::Literal(lit) => self.lower_literal(lit),
            ast::Expr::Var(name) => {
                // A bare reference to a nullary variant constructs that value.
                if let Some((enum_name, tag, fields)) = self.enums.lookup_variant(name)
                    && fields.is_empty()
                {
                    let enum_name = enum_name.to_string();
                    return self.lower_construct(&enum_name, tag, &[]);
                }
                self.lower_var(name)
            }
            ast::Expr::Binary { op, lhs, rhs } => self.lower_binary(*op, lhs, rhs),
            ast::Expr::Unary { op, expr } => self.lower_unary(*op, expr),
            ast::Expr::If {
                cond,
                then_branch,
                else_branch,
            } => self.lower_if(cond, then_branch, else_branch),
            ast::Expr::Let { bindings, body } => self.lower_let(bindings, body),
            ast::Expr::While { cond, body } => self.lower_while(cond, body),
            ast::Expr::Begin(exprs) => self.lower_begin(exprs),
            ast::Expr::Call { func, args } => self.lower_call(func, args),
            ast::Expr::Match { scrutinee, arms } => self.lower_match(scrutinee, arms),
            ast::Expr::Set(name, expr) => self.lower_set(name, expr),
            ast::Expr::Ann { expr, .. } => self.lower_expr(expr),
            ast::Expr::Cast { expr, ty } => self.lower_cast(expr, ty),
            // A dynamic-array constructor allocates an element buffer and builds
            // an inline fat `{ ptr, len }` value, yielding a pointer to it.
            ast::Expr::MakeArray { elem_ty, len } => self.lower_make_array(elem_ty, len),
            ast::Expr::ArrayRef { expr, index } => self.lower_array_ref(expr, index),
            ast::Expr::ArraySet { expr, index, value } => self.lower_array_set(expr, index, value),
            ast::Expr::StringRef { expr, index } => self.lower_string_ref(expr, index),
            ast::Expr::StructGet { expr, field } => self.lower_struct_get(expr, field),
            // Tuple, Array (literal), Lambda — stubbed to unit for now
            ast::Expr::Tuple(_) | ast::Expr::Array(_) | ast::Expr::Lambda { .. } => {
                Value::ConstUnit
            }
            ast::Expr::TupleRef { .. } => Value::ConstUnit,
            ast::Expr::Spanned { expr, .. } => self.lower_expr(expr),
        }
    }

    fn lower_literal(&mut self, lit: &ast::Literal) -> Value {
        match lit {
            ast::Literal::Int(n) => Value::ConstI64(*n),
            ast::Literal::Float(n) => Value::ConstF64(*n),
            ast::Literal::Bool(b) => Value::ConstBool(*b),
            ast::Literal::Char(c) => Value::ConstI8(*c as i8),
            ast::Literal::String(_) => Value::ConstUnit, // Not yet supported
            ast::Literal::Unit => Value::ConstUnit,
        }
    }

    fn lower_var(&mut self, name: &str) -> Value {
        if let Some(&var) = self.vars.get(name) {
            Value::Var(var)
        } else {
            // Global or external reference — treat as global for now
            Value::Global(name.to_string())
        }
    }

    fn lower_binary(&mut self, op: ast::BinOp, lhs: &ast::Expr, rhs: &ast::Expr) -> Value {
        let lhs_val = self.lower_expr(lhs);
        let rhs_val = self.lower_expr(rhs);

        // The IR op decides what the `ty` field means:
        //   - comparisons (eq/ne/lt/..) produce a `bool`, but the *operand*
        //     width/signedness drives the compare instruction selected by the
        //     backend, so we record the operand type, not bool;
        //   - shifts: the result type is the lhs (shifted) type; the rhs is the
        //     shift amount.
        // We recover the real operand type from `value_type`, which now tracks
        // every variable's declared width instead of defaulting to i64.
        let ir_op = match op {
            ast::BinOp::Add => BinOp::Add,
            ast::BinOp::Sub => BinOp::Sub,
            ast::BinOp::Mul => BinOp::Mul,
            ast::BinOp::Div => BinOp::Div,
            ast::BinOp::Mod => BinOp::Mod,
            ast::BinOp::Eq => BinOp::Eq,
            ast::BinOp::Ne => BinOp::Ne,
            ast::BinOp::Lt => BinOp::Lt,
            ast::BinOp::Le => BinOp::Le,
            ast::BinOp::Gt => BinOp::Gt,
            ast::BinOp::Ge => BinOp::Ge,
            ast::BinOp::And => BinOp::And,
            ast::BinOp::Or => BinOp::Or,
            ast::BinOp::BitAnd => BinOp::BitAnd,
            ast::BinOp::BitOr => BinOp::BitOr,
            ast::BinOp::BitXor => BinOp::BitXor,
            ast::BinOp::Shl => BinOp::Shl,
            ast::BinOp::Shr => BinOp::Shr,
        };

        // Operand type drives instruction width/signedness. Prefer a concrete
        // (non-default) operand type from either side.
        let operand_ty = self.binop_operand_type(&lhs_val, &rhs_val);

        // The *value* produced by the op: comparisons/logical ops yield bool,
        // everything else yields the operand type.
        let result_ty = match ir_op {
            BinOp::Eq
            | BinOp::Ne
            | BinOp::Lt
            | BinOp::Le
            | BinOp::Gt
            | BinOp::Ge
            | BinOp::And
            | BinOp::Or => Type::Bool,
            _ => operand_ty.clone(),
        };

        let dst = self.builder.fresh_var();
        self.builder.emit(Instruction::BinOp {
            dst,
            op: ir_op,
            lhs: lhs_val,
            rhs: rhs_val,
            ty: result_ty.clone(),
        });
        self.record_local(dst, result_ty.clone());
        Value::Var(dst)
    }

    fn lower_unary(&mut self, op: ast::UnOp, expr: &ast::Expr) -> Value {
        let src = self.lower_expr(expr);
        let (ir_op, ty) = match op {
            ast::UnOp::Neg => (UnOp::Neg, self.value_type(&src)),
            ast::UnOp::Not => (UnOp::Not, Type::Bool),
            // `bit-not` is a one's-complement on integers — distinct from the
            // boolean `not`. Preserve the integer width of the operand.
            ast::UnOp::BitNot => (UnOp::BitNot, self.value_type(&src)),
        };
        let dst = self.builder.fresh_var();
        self.builder.emit(Instruction::UnOp {
            dst,
            op: ir_op,
            src,
            ty: ty.clone(),
        });
        self.record_local(dst, ty);
        Value::Var(dst)
    }

    /// Lower `(cast expr : ty)` to a `Cast` instruction carrying both the
    /// source and target types so the backend can pick truncation vs sign/zero
    /// extension.
    fn lower_cast(&mut self, expr: &ast::Expr, to_ty: &Type) -> Value {
        let src = self.lower_expr(expr);
        let from_ty = self.value_type(&src);
        // A no-op cast (same representation) folds to the source value.
        if from_ty == *to_ty {
            return src;
        }
        let dst = self.builder.fresh_var();
        self.builder.emit(Instruction::Cast {
            dst,
            src,
            from_ty,
            to_ty: to_ty.clone(),
        });
        self.record_local(dst, to_ty.clone());
        Value::Var(dst)
    }

    /// Record a freshly-created IR variable's type in both the function frame
    /// (`locals`) and the lowerer's type map.
    fn record_local(&mut self, var: VarId, ty: Type) {
        self.var_types.insert(var, ty.clone());
        self.locals.push((var, ty));
    }

    fn resolved_struct_fields(&self, struct_name: &str) -> Vec<ast::FieldDef> {
        self.structs
            .fields(struct_name)
            .map(|fields| {
                fields
                    .iter()
                    .map(|field| ast::FieldDef {
                        name: field.name.clone(),
                        ty: self.resolve_type(&field.ty),
                    })
                    .collect()
            })
            .unwrap_or_default()
    }

    /// Recover the type of a binary op's operands, preferring a concrete
    /// (non-unit) type from either side. Char operands are treated as i8 for
    /// width purposes.
    fn binop_operand_type(&self, lhs: &Value, rhs: &Value) -> Type {
        let lt = self.value_type(lhs);
        let rt = self.value_type(rhs);
        // Prefer the more informative side: a sized integer/float over a
        // generic i64 default, and never pick Unit.
        match (&lt, &rt) {
            (Type::Unit, _) => rt,
            (_, Type::Unit) => lt,
            // If one side is a non-i64 sized type, it carries the real width.
            _ if lt != Type::I64 => lt,
            _ => rt,
        }
    }

    fn lower_if(
        &mut self,
        cond: &ast::Expr,
        then_branch: &ast::Expr,
        else_branch: &ast::Expr,
    ) -> Value {
        let cond_val = self.lower_expr(cond);

        let then_label = self.builder.fresh_label("then");
        let else_label = self.builder.fresh_label("else");
        let merge_label = self.builder.fresh_label("merge");

        self.builder.emit(Instruction::Branch {
            cond: cond_val,
            true_label: then_label.clone(),
            false_label: else_label.clone(),
        });

        // Then block
        self.builder.finish_block(&then_label);
        let then_val = self.lower_expr(then_branch);
        self.builder.emit(Instruction::Jump(merge_label.clone()));

        // Else block
        self.builder.finish_block(&else_label);
        let else_val = self.lower_expr(else_branch);
        self.builder.emit(Instruction::Jump(merge_label.clone()));

        // Merge block — phi to select result
        self.builder.finish_block(&merge_label);
        // Assume branches match (type-checked); prefer a concrete type from
        // either arm so the phi's width is right.
        let then_ty = self.value_type(&then_val);
        let result_ty = if then_ty == Type::Unit {
            self.value_type(&else_val)
        } else {
            then_ty
        };
        let phi_dst = self.builder.fresh_var();
        self.builder.emit(Instruction::Phi {
            dst: phi_dst,
            incoming: vec![
                (then_val, then_label.clone()),
                (else_val, else_label.clone()),
            ],
            ty: result_ty.clone(),
        });
        self.record_local(phi_dst, result_ty);
        Value::Var(phi_dst)
    }

    fn lower_let(
        &mut self,
        bindings: &[(String, Option<Type>, ast::Expr)],
        body: &ast::Expr,
    ) -> Value {
        for (name, ty, value) in bindings {
            let val = self.lower_expr(value);
            // Resolve a declared binding type so a `Type::Var` naming an enum or
            // struct becomes the nominal type; otherwise fall back to the
            // lowered value's recorded type.
            let binding_ty = ty
                .as_ref()
                .map(|t| self.resolve_type(t))
                .unwrap_or_else(|| self.value_type(&val));

            let var = self.builder.fresh_var();
            self.builder.emit(Instruction::Alloc {
                var,
                ty: binding_ty.clone(),
            });
            self.builder.emit(Instruction::Store {
                dst: Value::Var(var),
                src: val,
                ty: binding_ty.clone(),
            });
            self.record_local(var, binding_ty);
            self.vars.insert(name.clone(), var);
        }
        self.lower_expr(body)
    }

    fn lower_while(&mut self, cond: &ast::Expr, body: &ast::Expr) -> Value {
        let header_label = self.builder.fresh_label("while_header");
        let body_label = self.builder.fresh_label("while_body");
        let exit_label = self.builder.fresh_label("while_exit");

        // Jump to header
        self.builder.emit(Instruction::Jump(header_label.clone()));

        // Header block
        self.builder.finish_block(&header_label);
        let cond_val = self.lower_expr(cond);
        self.builder.emit(Instruction::Branch {
            cond: cond_val,
            true_label: body_label.clone(),
            false_label: exit_label.clone(),
        });

        // Body block
        self.builder.finish_block(&body_label);
        self.lower_expr(body);
        self.builder.emit(Instruction::Jump(header_label));

        // Exit block
        self.builder.finish_block(&exit_label);
        Value::ConstUnit
    }

    fn lower_begin(&mut self, exprs: &[ast::Expr]) -> Value {
        let mut last = Value::ConstUnit;
        for expr in exprs {
            last = self.lower_expr(expr);
        }
        last
    }

    fn lower_call(&mut self, func: &ast::Expr, args: &[ast::Expr]) -> Value {
        // A call whose head names a variant constructor builds an enum value
        // rather than dispatching to a function.
        if let ast::Expr::Var(name) = func.unspan()
            && let Some((enum_name, tag, _fields)) = self.enums.lookup_variant(name)
        {
            let enum_name = enum_name.to_string();
            let arg_vals: Vec<Value> = args.iter().map(|a| self.lower_expr(a)).collect();
            return self.lower_construct(&enum_name, tag, &arg_vals);
        }

        // A call whose head names a struct builds a struct value rather than
        // dispatching to a function.
        if let ast::Expr::Var(name) = func.unspan()
            && self.structs.is_struct(name)
        {
            let struct_name = name.clone();
            let arg_vals: Vec<Value> = args.iter().map(|a| self.lower_expr(a)).collect();
            return self.lower_construct_struct(&struct_name, &arg_vals);
        }

        // Fat-value length builtins are not runtime calls: lower the argument
        // first and dispatch on the recorded result type. This covers compound
        // array expressions such as `(let ... a)` and `(if ... a b)`, which the
        // lightweight AST type guesser cannot classify before lowering.
        if let ast::Expr::Var(name) = func.unspan()
            && (name == "array-length" || name == "string-length" || name == "length")
            && args.len() == 1
        {
            let fat = self.lower_expr(&args[0]);
            let len_offset = if matches!(self.value_type(&fat), Type::DynArray(_)) {
                DYN_ARRAY_LEN_OFFSET
            } else {
                STRING_LEN_OFFSET
            };
            return self.load_fat_len(&fat, len_offset);
        }

        // `(string-eq a b)` / `(string=? a b)` compare two strings byte-wise.
        // Each operand is a pointer to inline fat `{ ptr, len }` storage; extract
        // the data pointer (offset 0) and length (offset 8) of both operands and
        // dispatch to the emit-on-demand runtime `tl_string_eq(a_ptr, a_len,
        // b_ptr, b_len) -> i64 (0/1)`. A `Call` (not an inline Load/Gep loop) is
        // used so the byte comparison is never dropped by DCE — the optimizer's
        // `has_side_effects` treats `Load`/`Gep` as pure, but a `Call` survives.
        if let ast::Expr::Var(name) = func.unspan()
            && (name == "string-eq" || name == "string=?")
            && args.len() == 2
        {
            let a = self.lower_expr(&args[0]);
            let b = self.lower_expr(&args[1]);
            let (a_ptr, a_len) = self.load_string_fields(&a);
            let (b_ptr, b_len) = self.load_string_fields(&b);
            let dst = self.builder.fresh_var();
            self.builder.emit(Instruction::Call {
                dst: Some(dst),
                func: "tl_string_eq".to_string(),
                args: vec![
                    Value::Var(a_ptr),
                    Value::Var(a_len),
                    Value::Var(b_ptr),
                    Value::Var(b_len),
                ],
                ty: Type::Bool,
            });
            self.record_local(dst, Type::Bool);
            return Value::Var(dst);
        }

        // `(string->int s)` parses the decimal string `s` to an i64. The operand
        // is a pointer to inline fat `{ ptr, len }` storage; extract the data
        // pointer (offset 0) and length (offset 8) and dispatch to the
        // emit-on-demand runtime `tl_string_to_int(ptr, len) -> i64`. As with
        // `tl_string_eq`, a `Call` (not an inline parse loop) is used so the
        // computation survives DCE — the optimizer treats `Load`/`Gep` as pure.
        if let ast::Expr::Var(name) = func.unspan()
            && name == "string->int"
            && args.len() == 1
        {
            let s = self.lower_expr(&args[0]);
            let (ptr, len) = self.load_string_fields(&s);
            let dst = self.builder.fresh_var();
            self.builder.emit(Instruction::Call {
                dst: Some(dst),
                func: "tl_string_to_int".to_string(),
                args: vec![Value::Var(ptr), Value::Var(len)],
                ty: Type::I64,
            });
            self.record_local(dst, Type::I64);
            return Value::Var(dst);
        }

        // `(int->string n)` converts an i64 to its decimal-text String. The
        // result is a String value (a pointer to inline fat `{ ptr, len }`
        // storage), so it dispatches to the emit-on-demand runtime
        // `tl_int_to_string(n) -> ptr`, which heap-allocates both the digit
        // buffer and the fat value via `tl_alloc` so the returned pointer
        // outlives the caller's frame. A `Call` (not an inline divide loop) is
        // used so the conversion survives DCE, matching `string-eq`.
        if let ast::Expr::Var(name) = func.unspan()
            && name == "int->string"
            && args.len() == 1
        {
            let n_raw = self.lower_expr(&args[0]);
            let n_val = self.cast_value(n_raw, Type::I64);
            let dst = self.builder.fresh_var();
            self.builder.emit(Instruction::Call {
                dst: Some(dst),
                func: "tl_int_to_string".to_string(),
                args: vec![n_val],
                ty: Type::String,
            });
            self.record_local(dst, Type::String);
            return Value::Var(dst);
        }

        // Evaluate arguments left-to-right
        let arg_vals: Vec<Value> = args.iter().map(|a| self.lower_expr(a)).collect();

        let (func_name, ret_ty) = match func.unspan() {
            // A local binding shadows any top-level function of the same name.
            // If it has function type, call through the value in that slot.
            ast::Expr::Var(name) if self.vars.contains_key(name) => {
                let func_val = self.lower_expr(func);
                return self.lower_indirect_call(func_val, arg_vals);
            }
            ast::Expr::Var(name) => {
                let ret_ty = match self.function_types.get(name) {
                    Some(Type::Func(_, ret)) => (**ret).clone(),
                    _ => Type::Unit,
                };
                (name.clone(), ret_ty)
            }
            _ => {
                let func_val = self.lower_expr(func);
                return self.lower_indirect_call(func_val, arg_vals);
            }
        };

        if ret_ty == Type::Unit {
            self.builder.emit(Instruction::Call {
                dst: None,
                func: func_name,
                args: arg_vals,
                ty: Type::Unit,
            });
            return Value::ConstUnit;
        }

        let dst = self.builder.fresh_var();
        self.builder.emit(Instruction::Call {
            dst: Some(dst),
            func: func_name,
            args: arg_vals,
            ty: ret_ty.clone(),
        });
        self.record_local(dst, ret_ty);
        Value::Var(dst)
    }

    fn lower_indirect_call(&mut self, func_val: Value, arg_vals: Vec<Value>) -> Value {
        let ret_ty = match self.value_type(&func_val) {
            Type::Func(_, ret) => *ret,
            _ => Type::Unit,
        };

        if ret_ty == Type::Unit {
            self.builder.emit(Instruction::CallIndirect {
                dst: None,
                func: func_val,
                args: arg_vals,
                ty: Type::Unit,
            });
            return Value::ConstUnit;
        }

        let dst = self.builder.fresh_var();
        self.builder.emit(Instruction::CallIndirect {
            dst: Some(dst),
            func: func_val,
            args: arg_vals,
            ty: ret_ty.clone(),
        });
        self.record_local(dst, ret_ty);
        Value::Var(dst)
    }

    /// Reserve `size` bytes of inline aggregate storage and yield a
    /// pointer-typed (`storage_ty`) `Value::Var` to it.
    ///
    /// Storage placement is selected by `promote`:
    ///   - `promote == false`: a **frame** slot — emit `Alloc` (an i8 array of
    ///     exact `size`) then `AddrOf` to materialize its address. This is the
    ///     historical behavior; the value lives only for the current frame.
    ///   - `promote == true`: the **heap** — emit `Call tl_alloc(size)` (the same
    ///     runtime bump allocator `lower_make_array` uses for element buffers),
    ///     whose returned pointer is the storage address. A heap pointer outlives
    ///     the frame, so the value may safely escape via `return`.
    ///
    /// Heap promotion is applied only when the constructed value can reach the
    /// enclosing function's `return` (see `escapes_via_return`), so non-escaping
    /// local aggregates keep the cheaper frame allocation.
    fn reserve_aggregate_storage(&mut self, size: usize, storage_ty: Type, promote: bool) -> Value {
        if promote {
            // base = tl_alloc(size) : a heap pointer to `size` bytes. The
            // returned pointer *is* the storage address, so no Alloc/AddrOf
            // pair is needed; downstream Gep/Store operate on it unchanged.
            let base = self.builder.fresh_var();
            self.builder.emit(Instruction::Call {
                dst: Some(base),
                func: "tl_alloc".into(),
                args: vec![Value::ConstI64(size as i64)],
                ty: storage_ty.clone(),
            });
            self.record_local(base, storage_ty);
            return Value::Var(base);
        }
        // Reserve `size` bytes of inline storage as an i8 array (align 1, exact
        // size) so the backend allocates the right number of bytes.
        let slot = self.builder.fresh_var();
        let slot_ty = Type::Array(Box::new(Type::I8), size);
        self.builder.emit(Instruction::Alloc {
            var: slot,
            ty: slot_ty.clone(),
        });
        self.record_local(slot, slot_ty);

        // base = &slot : pointer to the frame storage.
        let base = self.builder.fresh_var();
        self.builder.emit(Instruction::AddrOf {
            dst: base,
            src: slot,
        });
        self.record_local(base, storage_ty);
        Value::Var(base)
    }

    /// Construct an enum value: reserve inline `{ tag, payload }` storage,
    /// store the variant tag, store each payload field at its byte offset, and
    /// yield a pointer to the storage (the runtime representation of an enum
    /// value). Uses only Alloc/AddrOf/Gep/Store (frame) or Call/Gep/Store
    /// (heap-promoted) — no new IR.
    fn lower_construct(&mut self, enum_name: &str, tag: usize, args: &[Value]) -> Value {
        let size = self.enums.enum_size(enum_name);
        let enum_ty = Type::Enum(enum_name.to_string());

        // Heap-promote when an enum value can escape via the function's return.
        let promote =
            type_kind_escapes_via_return(&self.ret, AggKind::Enum, &self.enums, &self.structs);
        let base_val = self.reserve_aggregate_storage(size, enum_ty.clone(), promote);

        // Store the tag at offset 0.
        let tag_ptr = self.gep_byte(&base_val, 0);
        self.builder.emit(Instruction::Store {
            dst: Value::Var(tag_ptr),
            src: Value::ConstI64(tag as i64),
            ty: Type::I64,
        });

        // Store each payload field at its (resolved) byte offset.
        let raw_fields: Vec<Type> = self.enums.lookup_variant_fields(enum_name, tag).to_vec();
        let field_tys: Vec<Type> = raw_fields.iter().map(|t| self.resolve_type(t)).collect();
        let offsets = self.enums.field_offsets(&field_tys);
        for ((arg, off), fty) in args.iter().zip(offsets.iter()).zip(field_tys.iter()) {
            let field_ptr = self.gep_byte(&base_val, *off);
            self.builder.emit(Instruction::Store {
                dst: Value::Var(field_ptr),
                src: arg.clone(),
                ty: fty.clone(),
            });
        }

        base_val
    }

    /// Construct a struct value: reserve inline field storage (no tag — a struct
    /// is a single untagged record), store each field at its byte offset, and
    /// yield a pointer to the storage (the runtime representation of a struct
    /// value). Mirrors `lower_construct` for enums but with no tag word, so the
    /// first field begins at offset 0. Uses only Alloc/AddrOf/Gep/Store (frame)
    /// or Call/Gep/Store (heap-promoted) — no new IR.
    fn lower_construct_struct(&mut self, struct_name: &str, args: &[Value]) -> Value {
        let struct_ty = Type::Struct(struct_name.to_string());
        let fields = self.resolved_struct_fields(struct_name);
        let field_tys: Vec<Type> = fields.iter().map(|f| f.ty.clone()).collect();
        let size = ast::StructRegistry::struct_size_for_types(&field_tys);

        // Heap-promote when a struct value can escape via the function's return.
        let promote =
            type_kind_escapes_via_return(&self.ret, AggKind::Struct, &self.enums, &self.structs);
        let base_val = self.reserve_aggregate_storage(size, struct_ty, promote);

        // Store each field at its (resolved) byte offset.
        let offsets = self.structs.field_offsets(&fields);
        for ((arg, off), fty) in args.iter().zip(offsets.iter()).zip(field_tys.iter()) {
            let field_ptr = self.gep_byte(&base_val, *off);
            self.builder.emit(Instruction::Store {
                dst: Value::Var(field_ptr),
                src: arg.clone(),
                ty: fty.clone(),
            });
        }

        base_val
    }

    /// Lower `(struct-get s field)`: compute the field's byte offset within the
    /// struct value `s` points at, `Gep` to the field address, and `Load` the
    /// field at its declared type. Mirrors how enum payload fields are read in a
    /// `match` arm — only Gep/Load, no new IR.
    fn lower_struct_get(&mut self, s: &ast::Expr, field: &str) -> Value {
        let s_val = self.lower_expr(s);
        let struct_name = match self.value_type(&s_val) {
            Type::Struct(name) => name,
            // Defensive: the typechecker rejects non-struct values here.
            _ => return Value::ConstUnit,
        };

        let fields = self.resolved_struct_fields(&struct_name);
        let offsets = self.structs.field_offsets(&fields);
        let Some(idx) = fields.iter().position(|f| f.name == field) else {
            return Value::ConstUnit;
        };
        let fty = fields[idx].ty.clone();
        let off = offsets[idx];

        let field_ptr = self.gep_byte(&s_val, off);
        let result = self.builder.fresh_var();
        self.builder.emit(Instruction::Load {
            dst: result,
            src: Value::Var(field_ptr),
            ty: fty.clone(),
        });
        self.record_local(result, fty);
        Value::Var(result)
    }

    /// Construct an immutable string literal value: reserve 16 bytes of inline
    /// fat-string storage `{ ptr, len }`, store the data pointer (a `ConstStr`
    /// the backend interns into `.rodata`) at offset 0, store the byte length at
    /// offset 8, and yield a pointer to the storage (the runtime representation
    /// of a string value). Uses only Alloc/AddrOf/Gep/Store (frame) or
    /// Call/Gep/Store (heap-promoted) — no new IR shape, mirroring how enum
    /// values are built (`lower_construct`).
    fn lower_string_literal(&mut self, text: &str) -> Value {
        // Heap-promote when a string value can escape via the function's return.
        let promote =
            type_kind_escapes_via_return(&self.ret, AggKind::String, &self.enums, &self.structs);
        let base_val = self.reserve_aggregate_storage(STRING_FAT_SIZE, Type::String, promote);

        // Store the data pointer at offset 0. `ConstStr` is materialized by the
        // backend as the address of the literal's interned `.rodata` bytes.
        let ptr_field = self.gep_byte(&base_val, STRING_PTR_OFFSET);
        self.builder.emit(Instruction::Store {
            dst: Value::Var(ptr_field),
            src: Value::ConstStr(text.to_string()),
            ty: Type::U64,
        });

        // Store the byte length at offset 8.
        let len_field = self.gep_byte(&base_val, STRING_LEN_OFFSET);
        self.builder.emit(Instruction::Store {
            dst: Value::Var(len_field),
            src: Value::ConstI64(text.len() as i64),
            ty: Type::I64,
        });

        base_val
    }

    /// Construct a dynamic-array value: reserve 16 bytes of inline fat
    /// `{ ptr, len }` storage, allocate an element buffer of `len * sizeof(elem)`
    /// bytes via the runtime bump allocator `tl_alloc`, store the buffer pointer
    /// at offset 0 and the element count at offset 8, then yield a pointer to the
    /// storage (the runtime representation of a dynamic array). Mirrors how enum
    /// values and string literals are built (`lower_construct`) — only
    /// Alloc/AddrOf/Gep/Store/Call, no new IR shape.
    fn lower_make_array(&mut self, elem_ty: &Type, len: &ast::Expr) -> Value {
        let elem_ty = self.resolve_type(elem_ty);
        let elem_size = elem_ty.size() as i64;
        let len_raw = self.lower_expr(len);
        let len_val = self.cast_value(len_raw, Type::I64);

        // byte_count = len * sizeof(elem). Computed in i64 so it feeds tl_alloc.
        let byte_count = self.builder.fresh_var();
        self.builder.emit(Instruction::BinOp {
            dst: byte_count,
            op: BinOp::Mul,
            lhs: len_val.clone(),
            rhs: Value::ConstI64(elem_size),
            ty: Type::I64,
        });
        self.record_local(byte_count, Type::I64);

        // buf = tl_alloc(byte_count) : the heap element buffer pointer.
        let buf = self.builder.fresh_var();
        self.builder.emit(Instruction::Call {
            dst: Some(buf),
            func: "tl_alloc".into(),
            args: vec![Value::Var(byte_count)],
            ty: Type::U64,
        });
        self.record_local(buf, Type::U64);

        // Reserve the fat-array `{ ptr, len }` storage (16 bytes). The element
        // buffer is always heap (`buf` above); the *fat value* itself is
        // heap-promoted only when a dynamic array can escape via the function's
        // return, so a non-escaping local array keeps its fat value on the frame.
        let arr_ty = Type::DynArray(Box::new(elem_ty));
        let promote =
            type_kind_escapes_via_return(&self.ret, AggKind::DynArray, &self.enums, &self.structs);
        let base_val = self.reserve_aggregate_storage(DYN_ARRAY_FAT_SIZE, arr_ty, promote);

        // Store the element-buffer pointer at offset 0.
        let ptr_field = self.gep_byte(&base_val, DYN_ARRAY_PTR_OFFSET);
        self.builder.emit(Instruction::Store {
            dst: Value::Var(ptr_field),
            src: Value::Var(buf),
            ty: Type::U64,
        });

        // Store the element count at offset 8.
        let len_field = self.gep_byte(&base_val, DYN_ARRAY_LEN_OFFSET);
        self.builder.emit(Instruction::Store {
            dst: Value::Var(len_field),
            src: len_val,
            ty: Type::I64,
        });

        base_val
    }

    /// Lower `(array-ref a i)`. For a *dynamic* array the access is bounds
    /// -checked: emit an UNSIGNED comparison `i u< len` (which also catches
    /// negative indices, since they wrap to huge unsigned values), branch to an
    /// abort block on out-of-bounds that emits a `Call tl_oob_abort` (the trap
    /// MUST be a `Call` — the optimizer's `has_side_effects` omits Load/Gep, so
    /// only a Call survives DCE), then on the in-bounds path compute the element
    /// address via `Gep` over the buffer pointer and `Load` the element.
    fn lower_array_ref(&mut self, arr: &ast::Expr, index: &ast::Expr) -> Value {
        let arr_val = self.lower_expr(arr);
        let arr_ty = self.value_type(&arr_val);
        // Only *dynamic* arrays are lowered here. Fixed-size `(Array elem N)`
        // value/stack arrays are still stubbed (their inline layout is a
        // separate, deferred slice), so fall through to a unit value as before.
        let elem_ty = match &arr_ty {
            Type::DynArray(e) => (**e).clone(),
            _ => return Value::ConstUnit,
        };

        let idx_val = self.lower_expr(index);
        let idx_u_val = self.cast_value(idx_val.clone(), Type::U64);
        let idx_offset_val = self.cast_value(idx_val, Type::I64);

        // Load len (offset 8) from the fat value.
        let len_ptr = self.gep_byte(&arr_val, DYN_ARRAY_LEN_OFFSET);
        let len = self.builder.fresh_var();
        self.builder.emit(Instruction::Load {
            dst: len,
            src: Value::Var(len_ptr),
            ty: Type::I64,
        });
        self.record_local(len, Type::I64);

        // Unsigned bounds check: in_bounds = (idx u< len). The operands are
        // reinterpreted as U64 via `Cast` so the backend selects the unsigned
        // condition code (`setb`) — negative indices wrap to large unsigned
        // values and so also fail the check. `Cast` (not `Mov`) is used because
        // the optimizer's copy propagation would substitute a `Mov` away,
        // restoring the signed operand and silently weakening the check.
        let len_u_val = self.cast_value(Value::Var(len), Type::U64);
        let in_bounds = self.builder.fresh_var();
        self.builder.emit(Instruction::BinOp {
            dst: in_bounds,
            op: BinOp::Lt,
            lhs: idx_u_val,
            rhs: len_u_val,
            ty: Type::Bool,
        });
        self.record_local(in_bounds, Type::Bool);

        let ok_label = self.builder.fresh_label("bounds_ok");
        let fail_label = self.builder.fresh_label("bounds_fail");
        self.builder.emit(Instruction::Branch {
            cond: Value::Var(in_bounds),
            true_label: ok_label.clone(),
            false_label: fail_label.clone(),
        });

        // Out-of-bounds block: call the abort runtime, then (defensively) jump
        // to the ok block. The call diverges at runtime so control never returns.
        self.builder.finish_block(&fail_label);
        self.builder.emit(Instruction::Call {
            dst: None,
            func: "tl_oob_abort".into(),
            args: vec![],
            ty: Type::Unit,
        });
        self.builder.emit(Instruction::Jump(ok_label.clone()));

        // In-bounds block: load the buffer pointer, compute the element address,
        // and load the element.
        self.builder.finish_block(&ok_label);
        let buf_ptr = self.gep_byte(&arr_val, DYN_ARRAY_PTR_OFFSET);
        let buf = self.builder.fresh_var();
        self.builder.emit(Instruction::Load {
            dst: buf,
            src: Value::Var(buf_ptr),
            ty: Type::U64,
        });
        self.record_local(buf, Type::U64);

        let elem_ptr = self.builder.fresh_var();
        self.builder.emit(Instruction::Gep {
            dst: elem_ptr,
            base: Value::Var(buf),
            offset: idx_offset_val,
            elem_ty: elem_ty.clone(),
        });
        self.record_local(elem_ptr, Type::U64);

        let result = self.builder.fresh_var();
        self.builder.emit(Instruction::Load {
            dst: result,
            src: Value::Var(elem_ptr),
            ty: elem_ty.clone(),
        });
        self.record_local(result, elem_ty);
        Value::Var(result)
    }

    /// Lower `(array-set! a i v)`. The store-side mirror of `lower_array_ref`:
    /// for a *dynamic* array the access is bounds-checked with the identical
    /// UNSIGNED `idx u< len` comparison (so negative indices wrap to huge
    /// unsigned values and also fail), branches to an abort block that emits a
    /// `Call tl_oob_abort` (the trap must be a Call: the optimizer's
    /// `has_side_effects` ignores Load/Gep, so a bare address computation would
    /// be dropped by DCE — a Call survives), then on the in-bounds path computes
    /// the element address via `Gep` over the buffer pointer and `Store`s the
    /// value in place. The `Store` itself is a side-effecting instruction, so it
    /// too survives DCE. No new allocation: the mutation hits the heap buffer the
    /// fat value already owns. Evaluates to Unit.
    fn lower_array_set(&mut self, arr: &ast::Expr, index: &ast::Expr, value: &ast::Expr) -> Value {
        let arr_val = self.lower_expr(arr);
        let arr_ty = self.value_type(&arr_val);
        // Only *dynamic* arrays are lowered here, exactly like `array-ref`:
        // fixed-size `(Array elem N)` value/stack arrays have a separate inline
        // layout that is still deferred, so fall through to a Unit value.
        let elem_ty = match &arr_ty {
            Type::DynArray(e) => (**e).clone(),
            _ => return Value::ConstUnit,
        };

        let idx_val = self.lower_expr(index);
        let idx_u_val = self.cast_value(idx_val.clone(), Type::U64);
        let idx_offset_val = self.cast_value(idx_val, Type::I64);

        // Evaluate the stored value before the bounds check (matching ordinary
        // left-to-right argument evaluation order; the value has no dependence
        // on the bounds outcome).
        let store_val = self.lower_expr(value);

        // Load len (offset 8) from the fat value.
        let len_ptr = self.gep_byte(&arr_val, DYN_ARRAY_LEN_OFFSET);
        let len = self.builder.fresh_var();
        self.builder.emit(Instruction::Load {
            dst: len,
            src: Value::Var(len_ptr),
            ty: Type::I64,
        });
        self.record_local(len, Type::I64);

        // Unsigned bounds check: in_bounds = (idx u< len). Both operands are
        // reinterpreted to U64 via `Cast` (NOT `Mov`, which copy-prop would fold
        // back to the signed operand and silently weaken the check) so the
        // backend selects the unsigned condition code (`setb`).
        let len_u_val = self.cast_value(Value::Var(len), Type::U64);
        let in_bounds = self.builder.fresh_var();
        self.builder.emit(Instruction::BinOp {
            dst: in_bounds,
            op: BinOp::Lt,
            lhs: idx_u_val,
            rhs: len_u_val,
            ty: Type::Bool,
        });
        self.record_local(in_bounds, Type::Bool);

        let ok_label = self.builder.fresh_label("set_bounds_ok");
        let fail_label = self.builder.fresh_label("set_bounds_fail");
        self.builder.emit(Instruction::Branch {
            cond: Value::Var(in_bounds),
            true_label: ok_label.clone(),
            false_label: fail_label.clone(),
        });

        // Out-of-bounds block: call the abort runtime, then (defensively) jump
        // to the ok block. The call diverges at runtime so control never returns.
        self.builder.finish_block(&fail_label);
        self.builder.emit(Instruction::Call {
            dst: None,
            func: "tl_oob_abort".into(),
            args: vec![],
            ty: Type::Unit,
        });
        self.builder.emit(Instruction::Jump(ok_label.clone()));

        // In-bounds block: load the buffer pointer, compute the element address,
        // and store the value through it (in place).
        self.builder.finish_block(&ok_label);
        let buf_ptr = self.gep_byte(&arr_val, DYN_ARRAY_PTR_OFFSET);
        let buf = self.builder.fresh_var();
        self.builder.emit(Instruction::Load {
            dst: buf,
            src: Value::Var(buf_ptr),
            ty: Type::U64,
        });
        self.record_local(buf, Type::U64);

        let elem_ptr = self.builder.fresh_var();
        self.builder.emit(Instruction::Gep {
            dst: elem_ptr,
            base: Value::Var(buf),
            offset: idx_offset_val,
            elem_ty: elem_ty.clone(),
        });
        self.record_local(elem_ptr, Type::U64);

        self.builder.emit(Instruction::Store {
            dst: Value::Var(elem_ptr),
            src: store_val,
            ty: elem_ty,
        });

        Value::ConstUnit
    }

    /// Lower `(string-ref s i)` / `(char-at s i)`: the bounds-checked byte at
    /// index `i` of String `s`, yielded as a `char`. This mirrors the dynamic
    /// `array-ref` lowering exactly — extract the fat `{ ptr, len }` fields,
    /// emit an UNSIGNED `idx u< len` compare (so negative indices wrap to huge
    /// unsigned values and also fail), branch to an abort block that emits a
    /// `Call tl_oob_abort` (a Call is the only form that survives DCE, since the
    /// optimizer's `has_side_effects` ignores Load/Gep), then on the in-bounds
    /// path `Gep` over the data pointer and `Load` a single byte. The byte load
    /// is typed `Char` (1 byte), which the backend zero-extends (`movzbq`).
    fn lower_string_ref(&mut self, s: &ast::Expr, index: &ast::Expr) -> Value {
        let str_val = self.lower_expr(s);
        // Defensive: anything that isn't a String value can't be indexed. The
        // typechecker rejects this, so just yield unit rather than miscompile.
        if !matches!(self.value_type(&str_val), Type::String) {
            return Value::ConstUnit;
        }

        let idx_val = self.lower_expr(index);
        let idx_u_val = self.cast_value(idx_val.clone(), Type::U64);
        let idx_offset_val = self.cast_value(idx_val, Type::I64);

        // Load len (offset 8) from the fat string value.
        let len_ptr = self.gep_byte(&str_val, STRING_LEN_OFFSET);
        let len = self.builder.fresh_var();
        self.builder.emit(Instruction::Load {
            dst: len,
            src: Value::Var(len_ptr),
            ty: Type::I64,
        });
        self.record_local(len, Type::I64);

        // Unsigned bounds check: in_bounds = (idx u< len). Both operands are
        // reinterpreted to U64 via `Cast` (not `Mov`, which copy-prop would fold
        // back to the signed operand and silently weaken the check) so the
        // backend selects the unsigned condition code (`setb`).
        let len_u_val = self.cast_value(Value::Var(len), Type::U64);
        let in_bounds = self.builder.fresh_var();
        self.builder.emit(Instruction::BinOp {
            dst: in_bounds,
            op: BinOp::Lt,
            lhs: idx_u_val,
            rhs: len_u_val,
            ty: Type::Bool,
        });
        self.record_local(in_bounds, Type::Bool);

        let ok_label = self.builder.fresh_label("str_bounds_ok");
        let fail_label = self.builder.fresh_label("str_bounds_fail");
        self.builder.emit(Instruction::Branch {
            cond: Value::Var(in_bounds),
            true_label: ok_label.clone(),
            false_label: fail_label.clone(),
        });

        // Out-of-bounds block: call the shared abort runtime, then (defensively)
        // jump to the ok block. The call diverges so control never returns.
        self.builder.finish_block(&fail_label);
        self.builder.emit(Instruction::Call {
            dst: None,
            func: "tl_oob_abort".into(),
            args: vec![],
            ty: Type::Unit,
        });
        self.builder.emit(Instruction::Jump(ok_label.clone()));

        // In-bounds block: load the data pointer, compute the byte address, and
        // load one byte as a `char`.
        self.builder.finish_block(&ok_label);
        let data_ptr = self.gep_byte(&str_val, STRING_PTR_OFFSET);
        let buf = self.builder.fresh_var();
        self.builder.emit(Instruction::Load {
            dst: buf,
            src: Value::Var(data_ptr),
            ty: Type::U64,
        });
        self.record_local(buf, Type::U64);

        let byte_ptr = self.builder.fresh_var();
        self.builder.emit(Instruction::Gep {
            dst: byte_ptr,
            base: Value::Var(buf),
            offset: idx_offset_val,
            elem_ty: Type::Char,
        });
        self.record_local(byte_ptr, Type::U64);

        let result = self.builder.fresh_var();
        self.builder.emit(Instruction::Load {
            dst: result,
            src: Value::Var(byte_ptr),
            ty: Type::Char,
        });
        self.record_local(result, Type::Char);
        Value::Var(result)
    }

    fn load_fat_len(&mut self, fat: &Value, len_offset: usize) -> Value {
        let len_ptr = self.gep_byte(fat, len_offset);
        let dst = self.builder.fresh_var();
        self.builder.emit(Instruction::Load {
            dst,
            src: Value::Var(len_ptr),
            ty: Type::I64,
        });
        self.record_local(dst, Type::I64);
        Value::Var(dst)
    }

    fn cast_value(&mut self, val: Value, to_ty: Type) -> Value {
        let from_ty = self.value_type(&val);
        if from_ty == to_ty {
            return val;
        }

        let dst = self.builder.fresh_var();
        self.builder.emit(Instruction::Cast {
            dst,
            src: val,
            from_ty,
            to_ty: to_ty.clone(),
        });
        self.record_local(dst, to_ty);
        Value::Var(dst)
    }

    /// Extract the `(data_ptr, len)` fields of a string fat value. `s` is a
    /// pointer to inline `{ ptr, len }` storage; load the data pointer (offset
    /// 0, U64) and the byte length (offset 8, I64) and return the two result
    /// vars. Used to feed `tl_string_eq`.
    fn load_string_fields(&mut self, s: &Value) -> (VarId, VarId) {
        let ptr_field = self.gep_byte(s, STRING_PTR_OFFSET);
        let ptr_dst = self.builder.fresh_var();
        self.builder.emit(Instruction::Load {
            dst: ptr_dst,
            src: Value::Var(ptr_field),
            ty: Type::U64,
        });
        self.record_local(ptr_dst, Type::U64);

        let len_field = self.gep_byte(s, STRING_LEN_OFFSET);
        let len_dst = self.builder.fresh_var();
        self.builder.emit(Instruction::Load {
            dst: len_dst,
            src: Value::Var(len_field),
            ty: Type::I64,
        });
        self.record_local(len_dst, Type::I64);

        (ptr_dst, len_dst)
    }

    /// Emit `dst = gep base, byte_offset : i8` — a pointer `byte_offset` bytes
    /// into the storage `base` points at. The i8 element type makes the Gep
    /// offset a raw byte count.
    fn gep_byte(&mut self, base: &Value, byte_offset: usize) -> VarId {
        let dst = self.builder.fresh_var();
        self.builder.emit(Instruction::Gep {
            dst,
            base: base.clone(),
            offset: Value::ConstI64(byte_offset as i64),
            elem_ty: Type::I8,
        });
        self.record_local(dst, Type::U64);
        dst
    }

    /// Lower `(match scrutinee [pat body] ...)` using the existing `if`
    /// template. For an *enum* scrutinee, the dispatch value is the loaded tag
    /// (offset 0) and arms are `Variant` patterns binding payload fields via
    /// `Gep`/`Load`. For a *scalar* scrutinee, the dispatch value is the
    /// scrutinee value itself and arms are `Literal` patterns compared by
    /// equality. Either way each refutable arm emits an `Eq` + `Branch`, a
    /// wildcard arm is the final fall-through, and a `Phi` in the merge block
    /// selects the result.
    fn lower_match(&mut self, scrutinee: &ast::Expr, arms: &[(ast::Pattern, ast::Expr)]) -> Value {
        let scrut = self.lower_expr(scrutinee);

        let scrut_ty = self.value_type(&scrut);
        let dispatch_val = if matches!(scrut_ty, Type::Enum(_)) {
            // Enum: load the tag (offset 0).
            let tag_ptr = self.gep_byte(&scrut, 0);
            let tag_val = self.builder.fresh_var();
            self.builder.emit(Instruction::Load {
                dst: tag_val,
                src: Value::Var(tag_ptr),
                ty: Type::I64,
            });
            self.record_local(tag_val, Type::I64);
            Value::Var(tag_val)
        } else {
            // Scalar: dispatch on the scrutinee value itself. This includes
            // wildcard-only scalar matches, which typecheck without literal
            // arms and must not be mistaken for enum tag dispatch.
            scrut.clone()
        };

        let merge_label = self.builder.fresh_label("match_end");
        let mut incoming: Vec<(Value, Label)> = Vec::new();
        let mut result_ty = Type::Unit;

        let n = arms.len();
        for (i, (pat, body)) in arms.iter().enumerate() {
            let is_last = i + 1 == n;
            match pat {
                ast::Pattern::Wildcard => {
                    // Irrefutable: lower the body in the current block and jump
                    // to the merge.
                    let val = self.lower_expr(body);
                    let arm_block = self.current_block_label();
                    if self.value_type(&val) != Type::Unit {
                        result_ty = self.value_type(&val);
                    }
                    incoming.push((val, arm_block));
                    self.builder.emit(Instruction::Jump(merge_label.clone()));
                    break;
                }
                ast::Pattern::Variant { name, bindings } => {
                    let (_owner, tag, raw_fields) = {
                        let (o, t, f) = self
                            .enums
                            .lookup_variant(name)
                            .expect("typechecked variant exists");
                        (o.to_string(), t, f.to_vec())
                    };
                    let field_tys: Vec<Type> =
                        raw_fields.iter().map(|t| self.resolve_type(t)).collect();
                    let offsets = self.enums.field_offsets(&field_tys);

                    let arm_label = self.builder.fresh_label("match_arm");
                    let next_label = self.builder.fresh_label("match_next");

                    // tag == this_tag ?
                    let cmp = self.builder.fresh_var();
                    self.builder.emit(Instruction::BinOp {
                        dst: cmp,
                        op: BinOp::Eq,
                        lhs: dispatch_val.clone(),
                        rhs: Value::ConstI64(tag as i64),
                        ty: Type::Bool,
                    });
                    self.record_local(cmp, Type::Bool);
                    self.builder.emit(Instruction::Branch {
                        cond: Value::Var(cmp),
                        true_label: arm_label.clone(),
                        false_label: next_label.clone(),
                    });

                    // Arm block: bind payload fields, lower the body.
                    self.builder.finish_block(&arm_label);
                    for ((binding, off), fty) in
                        bindings.iter().zip(offsets.iter()).zip(field_tys.iter())
                    {
                        let field_ptr = self.gep_byte(&scrut, *off);
                        let loaded = self.builder.fresh_var();
                        self.builder.emit(Instruction::Load {
                            dst: loaded,
                            src: Value::Var(field_ptr),
                            ty: fty.clone(),
                        });
                        self.record_local(loaded, fty.clone());
                        // Give the binding a real stack slot so nested control
                        // flow can read it.
                        let slot = self.builder.fresh_var();
                        self.builder.emit(Instruction::Alloc {
                            var: slot,
                            ty: fty.clone(),
                        });
                        self.builder.emit(Instruction::Store {
                            dst: Value::Var(slot),
                            src: Value::Var(loaded),
                            ty: fty.clone(),
                        });
                        self.record_local(slot, fty.clone());
                        self.vars.insert(binding.clone(), slot);
                    }
                    let val = self.lower_expr(body);
                    let arm_end = self.current_block_label();
                    if self.value_type(&val) != Type::Unit {
                        result_ty = self.value_type(&val);
                    }
                    incoming.push((val, arm_end));
                    self.builder.emit(Instruction::Jump(merge_label.clone()));

                    // Continue testing in the next block.
                    self.builder.finish_block(&next_label);
                    if is_last {
                        // Exhaustive match guarantees this is unreachable, but
                        // we still need a terminator into the merge.
                        self.builder.emit(Instruction::Jump(merge_label.clone()));
                    }
                }
                ast::Pattern::Literal(lit) => {
                    // Scalar match arm: compare the scrutinee value against the
                    // literal constant, then dispatch like a variant arm. No
                    // payload bindings.
                    let lit_val = self.lower_literal(lit);

                    let arm_label = self.builder.fresh_label("match_arm");
                    let next_label = self.builder.fresh_label("match_next");

                    // scrutinee == literal ? The backend recovers the compare
                    // width/signedness from the operands' value types.
                    let cmp = self.builder.fresh_var();
                    self.builder.emit(Instruction::BinOp {
                        dst: cmp,
                        op: BinOp::Eq,
                        lhs: dispatch_val.clone(),
                        rhs: lit_val,
                        ty: Type::Bool,
                    });
                    self.record_local(cmp, Type::Bool);
                    self.builder.emit(Instruction::Branch {
                        cond: Value::Var(cmp),
                        true_label: arm_label.clone(),
                        false_label: next_label.clone(),
                    });

                    // Arm block: lower the body (no bindings to install).
                    self.builder.finish_block(&arm_label);
                    let val = self.lower_expr(body);
                    let arm_end = self.current_block_label();
                    if self.value_type(&val) != Type::Unit {
                        result_ty = self.value_type(&val);
                    }
                    incoming.push((val, arm_end));
                    self.builder.emit(Instruction::Jump(merge_label.clone()));

                    // Continue testing in the next block.
                    self.builder.finish_block(&next_label);
                    if is_last {
                        self.builder.emit(Instruction::Jump(merge_label.clone()));
                    }
                }
                _ => {
                    // Var/Tuple patterns are rejected by the typechecker.
                }
            }
        }

        // Merge block with a phi selecting the taken arm's result.
        self.builder.finish_block(&merge_label);
        let phi_dst = self.builder.fresh_var();
        self.builder.emit(Instruction::Phi {
            dst: phi_dst,
            incoming,
            ty: result_ty.clone(),
        });
        self.record_local(phi_dst, result_ty);
        Value::Var(phi_dst)
    }

    /// The label of the block currently being built.
    fn current_block_label(&self) -> Label {
        self.builder.current_label().to_string()
    }

    fn lower_set(&mut self, name: &str, expr: &ast::Expr) -> Value {
        let val = self.lower_expr(expr);
        if let Some(&var) = self.vars.get(name) {
            // Store at the variable's declared width, not the (possibly wider)
            // type of the RHS value.
            let ty = self
                .var_types
                .get(&var)
                .cloned()
                .unwrap_or_else(|| self.value_type(&val));
            self.builder.emit(Instruction::Store {
                dst: Value::Var(var),
                src: val,
                ty,
            });
        } else if let Some(ty) = self.global_types.get(name).cloned() {
            self.builder.emit(Instruction::Store {
                dst: Value::Global(name.to_string()),
                src: val,
                ty,
            });
        }
        Value::ConstUnit
    }

    /// Recover the Type of a Value. For variables, consult the recorded type
    /// map (params/locals/temporaries all register their type), falling back
    /// to i64 only for variables we have no record of.
    fn value_type(&self, val: &Value) -> Type {
        match val {
            Value::ConstI64(_) => Type::I64,
            Value::ConstI32(_) => Type::I32,
            Value::ConstI8(_) => Type::I8,
            Value::ConstF64(_) => Type::F64,
            Value::ConstBool(_) => Type::Bool,
            Value::ConstUnit => Type::Unit,
            // A `ConstStr` operand is the raw data pointer of a string literal.
            Value::ConstStr(_) => Type::U64,
            Value::Var(v) => self.var_types.get(v).cloned().unwrap_or(Type::I64),
            Value::Global(name) => self.global_types.get(name).cloned().unwrap_or(Type::I64),
        }
    }

    /// Lower an expression to a standalone function with a Return.
    /// Used for global initializers.
    fn lower_expr_to_fn(mut self, expr: &ast::Expr, ret_ty: &Type) -> (Function, Value) {
        let result = self.lower_expr(expr);
        self.builder.emit(Instruction::Return(Some(result.clone())));
        let blocks = self.builder.build();
        let func = Function {
            name: self.name,
            params: self.params,
            ret: ret_ty.clone(),
            locals: self.locals,
            blocks,
            entry: "entry".into(),
        };
        (func, result)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ast;
    use crate::parser::parse;

    // ------------------------------------------------------------------
    // Existing tests
    // ------------------------------------------------------------------

    #[test]
    fn test_lower_simple_function() {
        let prog = parse(
            r#"
            (define (add [a : i64] [b : i64]) : i64 (+ a b))
        "#,
        )
        .unwrap();
        let ir = lower_program(&prog);
        assert_eq!(ir.functions.len(), 1);
        assert_eq!(ir.functions[0].name, "add");
        assert_eq!(ir.functions[0].params.len(), 2);
        assert_eq!(ir.functions[0].entry, "entry");

        // Check that there's a BinOp instruction
        let has_binop = ir.functions[0].blocks.iter().any(|b| {
            b.instructions
                .iter()
                .any(|i| matches!(i, Instruction::BinOp { .. }))
        });
        assert!(has_binop);
    }

    #[test]
    fn test_lower_cross_module_call_is_direct() {
        // Simulate the loader's concatenation: module a's function, then module
        // b's function (import stripped) that calls a's function. The call must
        // lower to a direct `Instruction::Call` targeting "a".
        let mut prog_a = parse("(define (a [x : i64]) : i64 (+ x 1))").unwrap();
        let prog_b = parse("(import \"a.tl\")\n(define (b) : i64 (a 41))").unwrap();
        for d in prog_b.decls {
            if !matches!(d, ast::Decl::Import(_)) {
                prog_a.decls.push(d);
            }
        }
        let ir = lower_program(&prog_a);
        // Find function b and confirm it emits a direct Call to "a".
        let b_fn = ir
            .functions
            .iter()
            .find(|f| f.name == "b")
            .expect("function b lowered");
        let calls_a = b_fn.blocks.iter().any(|blk| {
            blk.instructions
                .iter()
                .any(|i| matches!(i, Instruction::Call { func, .. } if func == "a"))
        });
        assert!(calls_a, "expected b to emit a direct Call to a");
    }

    #[test]
    fn test_lower_function_pointer_param_call_is_indirect() {
        let prog = parse(
            r#"
            (define (apply1 [f : (-> i64 i64)] [x : i64]) : i64
              (f x))
        "#,
        )
        .unwrap();
        let ir = lower_program(&prog);
        let apply = &ir.functions[0];
        let indirect = apply.blocks.iter().find_map(|blk| {
            blk.instructions.iter().find_map(|i| match i {
                Instruction::CallIndirect {
                    dst: Some(dst),
                    func,
                    args,
                    ty,
                } => Some((*dst, func.clone(), args.clone(), ty.clone())),
                _ => None,
            })
        });
        assert_eq!(
            indirect,
            Some((2, Value::Var(0), vec![Value::Var(1)], Type::I64))
        );

        let has_direct_f_call = apply.blocks.iter().any(|blk| {
            blk.instructions
                .iter()
                .any(|i| matches!(i, Instruction::Call { func, .. } if func == "f"))
        });
        assert!(!has_direct_f_call);
    }

    #[test]
    fn test_lower_float_param_binary_type() {
        let prog = parse(
            r#"
            (define (addf [a : f64] [b : f64]) : f64 (+ a b))
        "#,
        )
        .unwrap();
        let ir = lower_program(&prog);
        let has_f64_add = ir.functions[0].blocks.iter().any(|b| {
            b.instructions.iter().any(|i| {
                matches!(
                    i,
                    Instruction::BinOp {
                        op: BinOp::Add,
                        ty: Type::F64,
                        ..
                    }
                )
            })
        });
        assert!(has_f64_add);
    }

    #[test]
    fn test_lower_float_comparison_result_type() {
        let prog = parse(
            r#"
            (define (ltf [a : f64] [b : f64]) : bool (< a b))
        "#,
        )
        .unwrap();
        let ir = lower_program(&prog);
        let has_bool_cmp = ir.functions[0].blocks.iter().any(|b| {
            b.instructions.iter().any(|i| {
                matches!(
                    i,
                    Instruction::BinOp {
                        op: BinOp::Lt,
                        ty: Type::Bool,
                        ..
                    }
                )
            })
        });
        assert!(has_bool_cmp);
    }

    #[test]
    fn test_lower_if_expression() {
        let prog = parse(
            r#"
            (define (max [a : i64] [b : i64]) : i64
              (if (> a b) a b))
        "#,
        )
        .unwrap();
        let ir = lower_program(&prog);
        assert_eq!(ir.functions.len(), 1);

        let has_branch = ir.functions[0].blocks.iter().any(|b| {
            b.instructions
                .iter()
                .any(|i| matches!(i, Instruction::Branch { .. }))
        });
        assert!(has_branch);

        let has_phi = ir.functions[0].blocks.iter().any(|b| {
            b.instructions
                .iter()
                .any(|i| matches!(i, Instruction::Phi { .. }))
        });
        assert!(has_phi);
    }

    #[test]
    fn test_lower_while_loop() {
        let prog = parse(
            r#"
            (define (countdown [n : i64]) : i64
              (let ([x : i64 n])
                (begin
                  (while (> x 0)
                    (set! x (- x 1)))
                  x)))
        "#,
        )
        .unwrap();
        let ir = lower_program(&prog);
        assert_eq!(ir.functions.len(), 1);

        let has_jump = ir.functions[0].blocks.iter().any(|b| {
            b.instructions
                .iter()
                .any(|i| matches!(i, Instruction::Jump(..)))
        });
        assert!(has_jump);

        let has_branch = ir.functions[0].blocks.iter().any(|b| {
            b.instructions
                .iter()
                .any(|i| matches!(i, Instruction::Branch { .. }))
        });
        assert!(has_branch);
    }

    #[test]
    fn test_lower_let_binding() {
        let prog = parse(
            r#"
            (define (triple [x : i64]) : i64
              (let ([y : i64 (+ x x)])
                (+ y x)))
        "#,
        )
        .unwrap();
        let ir = lower_program(&prog);
        assert_eq!(ir.functions.len(), 1);

        let has_alloc = ir.functions[0].blocks.iter().any(|b| {
            b.instructions
                .iter()
                .any(|i| matches!(i, Instruction::Alloc { .. }))
        });
        assert!(has_alloc);
    }

    #[test]
    fn test_lower_globals() {
        let prog = parse(
            r#"
            (define result 42)
        "#,
        )
        .unwrap();
        let ir = lower_program(&prog);
        assert_eq!(ir.globals.len(), 1);
        assert_eq!(ir.globals[0].0, "result");
        assert_eq!(ir.globals[0].2, Some(Value::ConstI64(42)));
    }

    #[test]
    fn test_lower_casted_global_initializer_is_constant() {
        let prog = parse(
            r#"
            (define small : i32 (cast 7 : i32))
            (define byte : u8 (cast 255 : u8))
        "#,
        )
        .unwrap();
        let ir = lower_program(&prog);
        assert_eq!(ir.globals.len(), 2);
        assert_eq!(ir.globals[0].0, "small");
        assert_eq!(ir.globals[0].1, Type::I32);
        assert_eq!(ir.globals[0].2, Some(Value::ConstI32(7)));
        assert_eq!(ir.globals[1].0, "byte");
        assert_eq!(ir.globals[1].1, Type::U8);
        assert_eq!(ir.globals[1].2, Some(Value::ConstI8(-1)));
    }

    #[test]
    fn test_lower_extern() {
        let prog = parse(
            r#"
            (extern print : (-> i64 i64))
        "#,
        )
        .unwrap();
        let ir = lower_program(&prog);
        assert_eq!(ir.externs.len(), 1);
        assert_eq!(ir.externs[0].0, "print");
    }

    #[test]
    fn test_ir_pretty_print() {
        let prog = parse(
            r#"
            (define (add [a : i64] [b : i64]) : i64 (+ a b))
        "#,
        )
        .unwrap();
        let ir = lower_program(&prog);
        let display = format!("{}", ir);
        assert!(display.contains("function add"));
    }

    // ------------------------------------------------------------------
    // New comprehensive tests — Issue #23
    // ------------------------------------------------------------------

    // ---- Literals ------------------------------------------------------

    #[test]
    fn test_lower_float_literal() {
        let prog = parse(
            r#"
            (define (get_pi) : f64 3.14)
        "#,
        )
        .unwrap();
        let ir = lower_program(&prog);
        assert_eq!(ir.functions.len(), 1);

        let has_const_f64 = ir.functions[0].blocks.iter().any(|b| {
            b.instructions.iter().any(|i| {
                if let Instruction::Return(Some(Value::ConstF64(v))) = i {
                    (*v - 3.14).abs() < f64::EPSILON
                } else {
                    false
                }
            })
        });
        assert!(has_const_f64);
    }

    #[test]
    fn test_lower_char_literal() {
        // Char literal parsing from text is quirky; construct AST directly.
        let prog = ast::Program {
            decls: vec![ast::Decl::DefFn {
                name: "get_a".into(),
                params: vec![("x".into(), Type::Char)],
                ret: Type::Char,
                body: ast::Expr::Literal(ast::Literal::Char('a')),
            }],
        };
        let ir = lower_program(&prog);
        assert_eq!(ir.functions.len(), 1);

        let has_const_i8 = ir.functions[0].blocks.iter().any(|b| {
            b.instructions.iter().any(|i| {
                if let Instruction::Return(Some(Value::ConstI8(v))) = i {
                    *v == 'a' as i8
                } else {
                    false
                }
            })
        });
        assert!(has_const_i8);
    }

    #[test]
    fn test_lower_bool_literal() {
        let prog = parse(
            r#"
            (define (get_true) : bool true)
        "#,
        )
        .unwrap();
        let ir = lower_program(&prog);
        assert_eq!(ir.functions.len(), 1);

        let has_const_bool = ir.functions[0].blocks.iter().any(|b| {
            b.instructions.iter().any(|i| {
                if let Instruction::Return(Some(Value::ConstBool(v))) = i {
                    *v
                } else {
                    false
                }
            })
        });
        assert!(has_const_bool);
    }

    #[test]
    fn test_lower_unit_literal() {
        let prog = parse(
            r#"
            (define (noop) : i64 unit)
        "#,
        )
        .unwrap();
        let ir = lower_program(&prog);
        assert_eq!(ir.functions.len(), 1);

        let has_const_unit = ir.functions[0].blocks.iter().any(|b| {
            b.instructions.iter().any(|i| {
                if let Instruction::Return(Some(Value::ConstUnit)) = i {
                    true
                } else {
                    false
                }
            })
        });
        assert!(has_const_unit);
    }

    #[test]
    fn test_lower_unit_return_has_no_operand() {
        let prog = parse(
            r#"
            (define (noop) : unit unit)
        "#,
        )
        .unwrap();
        let ir = lower_program(&prog);
        assert_eq!(ir.functions.len(), 1);

        let has_empty_return = ir.functions[0].blocks.iter().any(|b| {
            b.instructions
                .iter()
                .any(|i| matches!(i, Instruction::Return(None)))
        });
        assert!(has_empty_return);
    }

    #[test]
    fn test_lower_string_literal_builds_fat_value() {
        // A string literal lowers to inline fat `{ ptr, len }` storage: an
        // Alloc of 16 bytes, a Store of the `ConstStr` data pointer and a Store
        // of the i64 length, mirroring how enum values are constructed.
        let prog = parse(
            r#"
            (define (greet [s : String]) : i64 (string-length "hello"))
        "#,
        )
        .unwrap();
        let ir = lower_program(&prog);
        assert_eq!(ir.functions.len(), 1);
        let instrs: Vec<&Instruction> = ir.functions[0]
            .blocks
            .iter()
            .flat_map(|b| b.instructions.iter())
            .collect();

        // 16-byte fat-string storage is reserved.
        assert!(instrs.iter().any(|i| matches!(
            i,
            Instruction::Alloc {
                ty: Type::Array(elem, 16),
                ..
            } if **elem == Type::I8
        )));

        // The data pointer is stored as a `ConstStr` carrying the literal bytes.
        assert!(instrs.iter().any(|i| matches!(
            i,
            Instruction::Store { src: Value::ConstStr(s), .. } if s == "hello"
        )));

        // The byte length (5) is stored as an i64.
        assert!(instrs.iter().any(|i| matches!(
            i,
            Instruction::Store {
                src: Value::ConstI64(5),
                ty: Type::I64,
                ..
            }
        )));

        // `string-length` lowers to a Load of the len field (not a runtime Call).
        assert!(!instrs.iter().any(|i| matches!(
            i,
            Instruction::Call { func, .. } if func == "string-length"
        )));
        assert!(
            instrs
                .iter()
                .any(|i| matches!(i, Instruction::Load { ty: Type::I64, .. }))
        );
    }

    #[test]
    fn test_lower_string_eq_extracts_fields_and_calls_runtime() {
        // `(string-eq a b)` lowers to: extract each operand's data pointer
        // (U64) and length (I64) fields, then a `Call tl_string_eq` with the
        // four args, whose result is a bool. A `Call` (not an inline loop) is
        // used so the byte comparison survives DCE.
        let prog = parse(r#"(define (eqp) : bool (string-eq "hi" "hi"))"#).unwrap();
        let ir = lower_program(&prog);
        let instrs: Vec<&Instruction> = ir.functions[0]
            .blocks
            .iter()
            .flat_map(|b| b.instructions.iter())
            .collect();

        // The runtime helper is called by name with four arguments.
        let call = instrs.iter().find_map(|i| match i {
            Instruction::Call { func, args, ty, .. } if func == "tl_string_eq" => Some((args, ty)),
            _ => None,
        });
        let (args, ty) = call.expect("expected a Call to tl_string_eq");
        assert_eq!(
            args.len(),
            4,
            "tl_string_eq takes ptr/len for both operands"
        );
        assert_eq!(*ty, Type::Bool, "string-eq yields a bool");

        // Both the data-pointer (U64) and length (I64) fields are loaded.
        assert!(
            instrs
                .iter()
                .any(|i| matches!(i, Instruction::Load { ty: Type::U64, .. })),
            "expected a Load of the U64 data-pointer field"
        );
        assert!(
            instrs
                .iter()
                .any(|i| matches!(i, Instruction::Load { ty: Type::I64, .. })),
            "expected a Load of the I64 length field"
        );
    }

    #[test]
    fn test_lower_string_to_int_extracts_fields_and_calls_runtime() {
        // `(string->int s)` lowers to: extract the operand's data pointer (U64)
        // and length (I64) fields, then a `Call tl_string_to_int` with the two
        // args, whose result is an i64. A `Call` (not an inline parse loop) is
        // used so the conversion survives DCE.
        let prog = parse(r#"(define (p) : i64 (string->int "42"))"#).unwrap();
        let ir = lower_program(&prog);
        let instrs: Vec<&Instruction> = ir.functions[0]
            .blocks
            .iter()
            .flat_map(|b| b.instructions.iter())
            .collect();

        // The runtime helper is called by name with two arguments.
        let call = instrs.iter().find_map(|i| match i {
            Instruction::Call { func, args, ty, .. } if func == "tl_string_to_int" => {
                Some((args, ty))
            }
            _ => None,
        });
        let (args, ty) = call.expect("expected a Call to tl_string_to_int");
        assert_eq!(args.len(), 2, "tl_string_to_int takes the operand ptr/len");
        assert_eq!(*ty, Type::I64, "string->int yields an i64");

        // Both the data-pointer (U64) and length (I64) fields are loaded.
        assert!(
            instrs
                .iter()
                .any(|i| matches!(i, Instruction::Load { ty: Type::U64, .. })),
            "expected a Load of the U64 data-pointer field"
        );
        assert!(
            instrs
                .iter()
                .any(|i| matches!(i, Instruction::Load { ty: Type::I64, .. })),
            "expected a Load of the I64 length field"
        );
    }

    #[test]
    fn test_lower_int_to_string_calls_runtime() {
        // `(int->string n)` lowers to a single `Call tl_int_to_string` taking the
        // i64 argument and yielding a String. A `Call` (not an inline divide
        // loop) is used so the conversion survives DCE.
        let prog = parse("(define (f [n : i64]) : String (int->string n))").unwrap();
        let ir = lower_program(&prog);
        let instrs: Vec<&Instruction> = ir.functions[0]
            .blocks
            .iter()
            .flat_map(|b| b.instructions.iter())
            .collect();

        let call = instrs.iter().find_map(|i| match i {
            Instruction::Call { func, args, ty, .. } if func == "tl_int_to_string" => {
                Some((args, ty))
            }
            _ => None,
        });
        let (args, ty) = call.expect("expected a Call to tl_int_to_string");
        assert_eq!(args.len(), 1, "int->string takes the single i64 operand");
        assert_eq!(*ty, Type::String, "int->string yields a String");
    }

    // ---- Expressions ---------------------------------------------------

    #[test]
    fn test_lower_unary_neg() {
        // Unary operators are not yet parsed from text; construct AST directly.
        let prog = ast::Program {
            decls: vec![ast::Decl::DefFn {
                name: "negate".into(),
                params: vec![("x".into(), Type::I64)],
                ret: Type::I64,
                body: ast::Expr::Unary {
                    op: ast::UnOp::Neg,
                    expr: Box::new(ast::Expr::Var("x".into())),
                },
            }],
        };
        let ir = lower_program(&prog);
        assert_eq!(ir.functions.len(), 1);

        let has_unop = ir.functions[0].blocks.iter().any(|b| {
            b.instructions.iter().any(|i| {
                if let Instruction::UnOp { op: UnOp::Neg, .. } = i {
                    true
                } else {
                    false
                }
            })
        });
        assert!(has_unop);
    }

    #[test]
    fn test_lower_unary_not() {
        let prog = ast::Program {
            decls: vec![ast::Decl::DefFn {
                name: "invert".into(),
                params: vec![("b".into(), Type::Bool)],
                ret: Type::Bool,
                body: ast::Expr::Unary {
                    op: ast::UnOp::Not,
                    expr: Box::new(ast::Expr::Var("b".into())),
                },
            }],
        };
        let ir = lower_program(&prog);
        assert_eq!(ir.functions.len(), 1);

        let has_unop = ir.functions[0].blocks.iter().any(|b| {
            b.instructions.iter().any(|i| {
                if let Instruction::UnOp { op: UnOp::Not, .. } = i {
                    true
                } else {
                    false
                }
            })
        });
        assert!(has_unop);
    }

    #[test]
    fn test_lower_begin() {
        let prog = parse(
            r#"
            (define (seq [x : i64]) : i64
              (begin
                (set! x (+ x 1))
                (set! x (+ x 1))
                x))
        "#,
        )
        .unwrap();
        let ir = lower_program(&prog);
        assert_eq!(ir.functions.len(), 1);

        // Begin should produce multiple binops and stores, returning the last expr.
        let binop_count = ir.functions[0].blocks.iter().fold(0, |acc, b| {
            acc + b
                .instructions
                .iter()
                .filter(|i| matches!(i, Instruction::BinOp { .. }))
                .count()
        });
        assert!(binop_count >= 2);

        let store_count = ir.functions[0].blocks.iter().fold(0, |acc, b| {
            acc + b
                .instructions
                .iter()
                .filter(|i| matches!(i, Instruction::Store { .. }))
                .count()
        });
        assert!(store_count >= 2);
    }

    #[test]
    fn test_lower_set() {
        let prog = parse(
            r#"
            (define (inc [x : i64]) : i64
              (begin
                (set! x (+ x 1))
                x))
        "#,
        )
        .unwrap();
        let ir = lower_program(&prog);
        assert_eq!(ir.functions.len(), 1);

        let has_store = ir.functions[0].blocks.iter().any(|b| {
            b.instructions
                .iter()
                .any(|i| matches!(i, Instruction::Store { .. }))
        });
        assert!(has_store);
    }

    #[test]
    fn test_lower_set_global_emits_store_to_global() {
        let prog = parse(
            r#"
            (define counter 0)
            (define (f) : i64
              (begin
                (set! counter 5)
                counter))
        "#,
        )
        .unwrap();
        let ir = lower_program(&prog);
        let has_global_store = ir.functions[0].blocks.iter().any(|b| {
            b.instructions.iter().any(|i| {
                matches!(
                    i,
                    Instruction::Store {
                        dst: Value::Global(name),
                        src: Value::ConstI64(5),
                        ty: Type::I64,
                    } if name == "counter"
                )
            })
        });
        assert!(has_global_store);
    }

    #[test]
    fn test_lower_ann_stripped() {
        // Type annotations should be stripped and the inner expression lowered.
        let prog = parse(
            r#"
            (define (get_val) : i64 (ann 42 : i64))
        "#,
        )
        .unwrap();
        let ir = lower_program(&prog);
        assert_eq!(ir.functions.len(), 1);

        let has_const_42 = ir.functions[0].blocks.iter().any(|b| {
            b.instructions.iter().any(|i| {
                if let Instruction::Return(Some(Value::ConstI64(42))) = i {
                    true
                } else {
                    false
                }
            })
        });
        assert!(has_const_42);
    }

    // ---- Functions -----------------------------------------------------

    #[test]
    fn test_lower_multiple_params() {
        let prog = parse(
            r#"
            (define (add3 [a : i64] [b : i64] [c : i64]) : i64
              (+ (+ a b) c))
        "#,
        )
        .unwrap();
        let ir = lower_program(&prog);
        assert_eq!(ir.functions.len(), 1);
        assert_eq!(ir.functions[0].name, "add3");
        assert_eq!(ir.functions[0].params.len(), 3);
    }

    #[test]
    fn test_lower_void_return() {
        let prog = parse(
            r#"
            (define (say_hi [x : i64]) : i64
              unit)
        "#,
        )
        .unwrap();
        let ir = lower_program(&prog);
        assert_eq!(ir.functions.len(), 1);
        assert_eq!(ir.functions[0].ret, Type::I64);

        let has_unit_ret = ir.functions[0].blocks.iter().any(|b| {
            b.instructions.iter().any(|i| {
                if let Instruction::Return(Some(Value::ConstUnit)) = i {
                    true
                } else {
                    false
                }
            })
        });
        assert!(has_unit_ret);
    }

    #[test]
    fn test_lower_no_params() {
        let prog = parse(
            r#"
            (define (answer) : i64 42)
        "#,
        )
        .unwrap();
        let ir = lower_program(&prog);
        assert_eq!(ir.functions.len(), 1);
        assert_eq!(ir.functions[0].name, "answer");
        assert!(ir.functions[0].params.is_empty());
    }

    // ---- Edge Cases ----------------------------------------------------

    #[test]
    fn test_lower_unknown_var_becomes_global() {
        let prog = ast::Program {
            decls: vec![ast::Decl::DefFn {
                name: "use_global".into(),
                params: vec![],
                ret: Type::I64,
                body: ast::Expr::Var("unknown_global".into()),
            }],
        };
        let ir = lower_program(&prog);
        assert_eq!(ir.functions.len(), 1);

        let has_global = ir.functions[0].blocks.iter().any(|b| {
            b.instructions.iter().any(|i| {
                if let Instruction::Return(Some(Value::Global(name))) = i {
                    name == "unknown_global"
                } else {
                    false
                }
            })
        });
        assert!(has_global);
    }

    #[test]
    fn test_lower_nested_if() {
        let prog = parse(
            r#"
            (define (clamp [x : i64]) : i64
              (if (< x 0)
                0
                (if (> x 100)
                  100
                  x)))
        "#,
        )
        .unwrap();
        let ir = lower_program(&prog);
        assert_eq!(ir.functions.len(), 1);

        let branch_count = ir.functions[0].blocks.iter().fold(0, |acc, b| {
            acc + b
                .instructions
                .iter()
                .filter(|i| matches!(i, Instruction::Branch { .. }))
                .count()
        });
        assert_eq!(branch_count, 2);

        let phi_count = ir.functions[0].blocks.iter().fold(0, |acc, b| {
            acc + b
                .instructions
                .iter()
                .filter(|i| matches!(i, Instruction::Phi { .. }))
                .count()
        });
        assert_eq!(phi_count, 2);
    }

    #[test]
    fn test_lower_nested_calls() {
        let prog = parse(
            r#"
            (define (f [x : i64]) : i64 (+ x 1))
            (define (g [x : i64]) : i64 (f (f x)))
        "#,
        )
        .unwrap();
        let ir = lower_program(&prog);
        assert_eq!(ir.functions.len(), 2);
        assert_eq!(ir.functions[1].name, "g");

        let call_count = ir.functions[1].blocks.iter().fold(0, |acc, b| {
            acc + b
                .instructions
                .iter()
                .filter(|i| matches!(i, Instruction::Call { .. }))
                .count()
        });
        assert_eq!(call_count, 2);
    }

    #[test]
    fn test_lower_direct_call_return_type() {
        let prog = parse(
            r#"
            (define (id_f64 [x : f64]) : f64 x)
            (define (main) : f64 (id_f64 1.5))
        "#,
        )
        .unwrap();
        let ir = lower_program(&prog);
        let main = &ir.functions[1];
        let has_f64_call = main.blocks.iter().any(|b| {
            b.instructions.iter().any(|i| {
                matches!(
                    i,
                    Instruction::Call {
                        func,
                        ty: Type::F64,
                        ..
                    } if func == "id_f64"
                )
            })
        });
        assert!(has_f64_call);
    }

    #[test]
    fn test_lower_complex_control_flow() {
        let prog = parse(
            r#"
            (define (foo [n : i64]) : i64
              (let ([acc : i64 0])
                (begin
                  (if (> n 0)
                    (set! acc n)
                    unit)
                  (while (> acc 0)
                    (set! acc (- acc 1)))
                  acc)))
        "#,
        )
        .unwrap();
        let ir = lower_program(&prog);
        assert_eq!(ir.functions.len(), 1);

        let has_branch = ir.functions[0].blocks.iter().any(|b| {
            b.instructions
                .iter()
                .any(|i| matches!(i, Instruction::Branch { .. }))
        });
        assert!(has_branch);

        let has_jump = ir.functions[0].blocks.iter().any(|b| {
            b.instructions
                .iter()
                .any(|i| matches!(i, Instruction::Jump(..)))
        });
        assert!(has_jump);

        let has_phi = ir.functions[0].blocks.iter().any(|b| {
            b.instructions
                .iter()
                .any(|i| matches!(i, Instruction::Phi { .. }))
        });
        assert!(has_phi);
    }

    #[test]
    fn test_lower_global_float() {
        let prog = parse(
            r#"
            (define pi 3.14)
        "#,
        )
        .unwrap();
        let ir = lower_program(&prog);
        assert_eq!(ir.globals.len(), 1);
        assert_eq!(ir.globals[0].0, "pi");
        assert!(
            matches!(ir.globals[0].2, Some(Value::ConstF64(v)) if (v - 3.14).abs() < f64::EPSILON)
        );
    }

    #[test]
    fn test_lower_global_bool() {
        let prog = parse(
            r#"
            (define flag true)
        "#,
        )
        .unwrap();
        let ir = lower_program(&prog);
        assert_eq!(ir.globals.len(), 1);
        assert_eq!(ir.globals[0].0, "flag");
        assert_eq!(ir.globals[0].2, Some(Value::ConstBool(true)));
    }

    #[test]
    fn test_lower_global_unit() {
        let prog = parse(
            r#"
            (define nothing unit)
        "#,
        )
        .unwrap();
        let ir = lower_program(&prog);
        assert_eq!(ir.globals.len(), 1);
        assert_eq!(ir.globals[0].0, "nothing");
        assert_eq!(ir.globals[0].2, Some(Value::ConstUnit));
    }

    // ---- Stubs (currently unimplemented in lowerer) --------------------

    #[test]
    fn test_lower_tuple_stub() {
        // Tuple lowering is stubbed to ConstUnit.
        let prog = parse(
            r#"
            (define (make_pair [a : i64] [b : bool]) : (Tuple i64 bool)
              (tuple a b))
        "#,
        )
        .unwrap();
        let ir = lower_program(&prog);
        assert_eq!(ir.functions.len(), 1);

        let has_unit_ret = ir.functions[0].blocks.iter().any(|b| {
            b.instructions.iter().any(|i| {
                if let Instruction::Return(Some(Value::ConstUnit)) = i {
                    true
                } else {
                    false
                }
            })
        });
        assert!(has_unit_ret);
    }

    #[test]
    fn test_lower_array_stub() {
        // Array lowering is stubbed to ConstUnit.
        let prog = parse(
            r#"
            (define (make_arr) : (Array i64 3)
              (array 1 2 3))
        "#,
        )
        .unwrap();
        let ir = lower_program(&prog);
        assert_eq!(ir.functions.len(), 1);

        let has_unit_ret = ir.functions[0].blocks.iter().any(|b| {
            b.instructions.iter().any(|i| {
                if let Instruction::Return(Some(Value::ConstUnit)) = i {
                    true
                } else {
                    false
                }
            })
        });
        assert!(has_unit_ret);
    }

    #[test]
    fn test_lower_lambda_stub() {
        // Lambda lowering is stubbed to ConstUnit.
        let prog = parse(
            r#"
            (define (get_fn) : (-> i64 i64)
              (lambda ([x : i64]) : i64 x))
        "#,
        )
        .unwrap();
        let ir = lower_program(&prog);
        assert_eq!(ir.functions.len(), 1);

        let has_unit_ret = ir.functions[0].blocks.iter().any(|b| {
            b.instructions.iter().any(|i| {
                if let Instruction::Return(Some(Value::ConstUnit)) = i {
                    true
                } else {
                    false
                }
            })
        });
        assert!(has_unit_ret);
    }

    #[test]
    fn test_lower_tuple_ref_stub() {
        // Tuple-ref lowering is stubbed to ConstUnit.
        let prog = parse(
            r#"
            (define (first [t : (Tuple i64 bool)]) : i64
              (tuple-ref t 0))
        "#,
        )
        .unwrap();
        let ir = lower_program(&prog);
        assert_eq!(ir.functions.len(), 1);

        let has_unit_ret = ir.functions[0].blocks.iter().any(|b| {
            b.instructions.iter().any(|i| {
                if let Instruction::Return(Some(Value::ConstUnit)) = i {
                    true
                } else {
                    false
                }
            })
        });
        assert!(has_unit_ret);
    }

    #[test]
    fn test_lower_array_ref_stub() {
        // Array-ref lowering is stubbed to ConstUnit.
        let prog = parse(
            r#"
            (define (first [a : (Array i64 3)]) : i64
              (array-ref a 0))
        "#,
        )
        .unwrap();
        let ir = lower_program(&prog);
        assert_eq!(ir.functions.len(), 1);

        let has_unit_ret = ir.functions[0].blocks.iter().any(|b| {
            b.instructions.iter().any(|i| {
                if let Instruction::Return(Some(Value::ConstUnit)) = i {
                    true
                } else {
                    false
                }
            })
        });
        assert!(has_unit_ret);
    }

    // ------------------------------------------------------------------
    // Dynamic arrays — Issue #13
    // ------------------------------------------------------------------

    fn all_instrs(ir: &Program) -> Vec<&Instruction> {
        ir.functions[0]
            .blocks
            .iter()
            .flat_map(|b| b.instructions.iter())
            .collect()
    }

    #[test]
    fn test_lower_make_array_allocates_and_builds_fat_value() {
        // `(make-array i64 n)` calls tl_alloc(n * 8), reserves 16-byte fat
        // storage, and stores the buffer pointer + element count.
        let prog = parse("(define (f [n : i64]) : i64 (begin (make-array i64 n) 0))").unwrap();
        let ir = lower_program(&prog);
        let instrs = all_instrs(&ir);

        // Element-buffer size is computed as n * sizeof(i64) = n * 8.
        assert!(instrs.iter().any(|i| matches!(
            i,
            Instruction::BinOp {
                op: BinOp::Mul,
                rhs: Value::ConstI64(8),
                ..
            }
        )));

        // The buffer is allocated via the runtime bump allocator.
        assert!(instrs.iter().any(|i| matches!(
            i,
            Instruction::Call { func, .. } if func == "tl_alloc"
        )));

        // 16-byte fat-array storage is reserved.
        assert!(instrs.iter().any(|i| matches!(
            i,
            Instruction::Alloc { ty: Type::Array(elem, 16), .. } if **elem == Type::I8
        )));

        // The element count is stored as an i64 (the len field).
        assert!(
            instrs
                .iter()
                .any(|i| matches!(i, Instruction::Store { ty: Type::I64, .. }))
        );
    }

    #[test]
    fn test_lower_make_array_scales_by_element_size() {
        // A u32 element array scales the byte count by 4.
        let prog = parse("(define (f [n : i64]) : i64 (begin (make-array u32 n) 0))").unwrap();
        let ir = lower_program(&prog);
        assert!(all_instrs(&ir).iter().any(|i| matches!(
            i,
            Instruction::BinOp {
                op: BinOp::Mul,
                rhs: Value::ConstI64(4),
                ..
            }
        )));
    }

    #[test]
    fn test_lower_make_array_widens_narrow_length_before_i64_math() {
        // The typechecker accepts any integer length; lowering must not read a
        // narrow parameter as an i64 stack slot.
        let prog = parse("(define (f [n : i32]) : i64 (begin (make-array i64 n) 0))").unwrap();
        let ir = lower_program(&prog);
        assert!(all_instrs(&ir).iter().any(|i| matches!(
            i,
            Instruction::Cast {
                from_ty: Type::I32,
                to_ty: Type::I64,
                ..
            }
        )));
    }

    #[test]
    fn test_lower_array_ref_bounds_checks_with_call_trap() {
        // `array-ref` on a dynamic array emits an unsigned bounds compare, a
        // Branch, a Call to the abort runtime (so DCE can't drop it), then a
        // Gep + Load of the element.
        let prog = parse("(define (f [a : (Array i64)] [i : i64]) : i64 (array-ref a i))").unwrap();
        let ir = lower_program(&prog);
        let instrs = all_instrs(&ir);

        // Unsigned compare: a Lt BinOp over U64-typed operands.
        assert!(instrs.iter().any(|i| matches!(
            i,
            Instruction::BinOp {
                op: BinOp::Lt,
                ty: Type::Bool,
                ..
            }
        )));
        assert!(
            instrs
                .iter()
                .any(|i| matches!(i, Instruction::Branch { .. }))
        );

        // The out-of-bounds trap is a Call (not a Load/Gep) so it survives DCE.
        assert!(instrs.iter().any(|i| matches!(
            i,
            Instruction::Call { func, dst: None, .. } if func == "tl_oob_abort"
        )));

        // The element address is computed via Gep over an i64 element type.
        assert!(instrs.iter().any(|i| matches!(
            i,
            Instruction::Gep {
                elem_ty: Type::I64,
                ..
            }
        )));
        assert!(
            instrs
                .iter()
                .any(|i| matches!(i, Instruction::Load { ty: Type::I64, .. }))
        );
    }

    #[test]
    fn test_lower_array_set_bounds_checks_then_stores() {
        // `array-set!` is the store-side mirror of `array-ref`: an unsigned
        // bounds compare, a Branch, a Call to the abort runtime (so DCE can't
        // drop it), then a Gep + Store of the element (in place).
        let prog =
            parse("(define (f [a : (Array i64)] [i : i64] [v : i64]) : unit (array-set! a i v))")
                .unwrap();
        let ir = lower_program(&prog);
        let instrs = all_instrs(&ir);

        // Unsigned compare: a Lt BinOp over U64-typed operands.
        assert!(instrs.iter().any(|i| matches!(
            i,
            Instruction::BinOp {
                op: BinOp::Lt,
                ty: Type::Bool,
                ..
            }
        )));
        assert!(
            instrs
                .iter()
                .any(|i| matches!(i, Instruction::Branch { .. }))
        );

        // The out-of-bounds trap is a Call (not a Store/Gep) so it survives DCE.
        assert!(instrs.iter().any(|i| matches!(
            i,
            Instruction::Call { func, dst: None, .. } if func == "tl_oob_abort"
        )));

        // The element address is computed via Gep over an i64 element type, and
        // the value is written with a Store (not a Load — this is the mutation).
        assert!(instrs.iter().any(|i| matches!(
            i,
            Instruction::Gep {
                elem_ty: Type::I64,
                ..
            }
        )));
        assert!(
            instrs
                .iter()
                .any(|i| matches!(i, Instruction::Store { ty: Type::I64, .. }))
        );
    }

    #[test]
    fn test_lower_array_set_widens_narrow_index() {
        // A narrow (i32) index is widened both for the unsigned bounds compare
        // (Cast to U64) and for address scaling (Cast to I64), like `array-ref`.
        let prog =
            parse("(define (f [a : (Array i64)] [i : i32] [v : i64]) : unit (array-set! a i v))")
                .unwrap();
        let ir = lower_program(&prog);
        let instrs = all_instrs(&ir);

        assert!(instrs.iter().any(|i| matches!(
            i,
            Instruction::Cast {
                from_ty: Type::I32,
                to_ty: Type::U64,
                ..
            }
        )));
        assert!(instrs.iter().any(|i| matches!(
            i,
            Instruction::Cast {
                from_ty: Type::I32,
                to_ty: Type::I64,
                ..
            }
        )));
    }

    #[test]
    fn test_lower_array_ref_handles_dynamic_array_from_let() {
        let prog = parse(
            "(define (f [n : i64] [i : i64]) : i64 \
               (array-ref (let ([a : (Array i64) (make-array i64 n)]) a) i))",
        )
        .unwrap();
        let ir = lower_program(&prog);
        let instrs = all_instrs(&ir);

        assert!(instrs.iter().any(|i| matches!(
            i,
            Instruction::Call { func, dst: None, .. } if func == "tl_oob_abort"
        )));
        assert!(instrs.iter().any(|i| matches!(
            i,
            Instruction::Gep {
                elem_ty: Type::I64,
                ..
            }
        )));
    }

    #[test]
    fn test_lower_array_ref_widens_narrow_index_for_bounds_and_addressing() {
        let prog = parse("(define (f [a : (Array i64)] [i : i32]) : i64 (array-ref a i))").unwrap();
        let ir = lower_program(&prog);
        let instrs = all_instrs(&ir);

        assert!(instrs.iter().any(|i| matches!(
            i,
            Instruction::Cast {
                from_ty: Type::I32,
                to_ty: Type::U64,
                ..
            }
        )));
        assert!(instrs.iter().any(|i| matches!(
            i,
            Instruction::Cast {
                from_ty: Type::I32,
                to_ty: Type::I64,
                ..
            }
        )));
    }

    #[test]
    fn test_lower_string_ref_bounds_checks_with_call_trap() {
        // `string-ref` mirrors dynamic `array-ref`: an unsigned bounds compare,
        // a Branch, a Call to the abort runtime (so DCE can't drop it), then a
        // Gep over a char element + a single-byte (char) Load.
        let prog = parse("(define (f [s : String] [i : i64]) : char (string-ref s i))").unwrap();
        let ir = lower_program(&prog);
        let instrs = all_instrs(&ir);

        // Unsigned compare: a Lt BinOp over U64-typed operands (the Cast to U64
        // of both operands forces the backend's unsigned condition code).
        assert!(instrs.iter().any(|i| matches!(
            i,
            Instruction::BinOp {
                op: BinOp::Lt,
                ty: Type::Bool,
                ..
            }
        )));
        assert!(instrs.iter().any(|i| matches!(
            i,
            Instruction::Cast {
                to_ty: Type::U64,
                ..
            }
        )));
        assert!(
            instrs
                .iter()
                .any(|i| matches!(i, Instruction::Branch { .. }))
        );

        // The out-of-bounds trap is a Call (not a Load/Gep) so it survives DCE.
        assert!(instrs.iter().any(|i| matches!(
            i,
            Instruction::Call { func, dst: None, .. } if func == "tl_oob_abort"
        )));

        // The byte address is computed via Gep over a char (1-byte) element, and
        // the result is a single-byte char Load.
        assert!(instrs.iter().any(|i| matches!(
            i,
            Instruction::Gep {
                elem_ty: Type::Char,
                ..
            }
        )));
        assert!(
            instrs
                .iter()
                .any(|i| matches!(i, Instruction::Load { ty: Type::Char, .. }))
        );
    }

    #[test]
    fn test_lower_string_ref_reads_len_field_for_bounds() {
        // The bounds check reads the fat string's len field (an i64 Load) rather
        // than calling a runtime length helper.
        let prog = parse(r#"(define (f) : char (string-ref "hello" 0))"#).unwrap();
        let ir = lower_program(&prog);
        let instrs = all_instrs(&ir);
        assert!(
            instrs
                .iter()
                .any(|i| matches!(i, Instruction::Load { ty: Type::I64, .. })),
            "expected an i64 Load of the len field"
        );
        assert!(instrs.iter().any(|i| matches!(
            i,
            Instruction::Call { func, dst: None, .. } if func == "tl_oob_abort"
        )));
    }

    #[test]
    fn test_lower_length_reads_len_field_not_a_call() {
        // `(length a)` / `(array-length a)` load the fat value's len field; they
        // are not runtime calls.
        let prog = parse("(define (f [a : (Array i64)]) : i64 (length a))").unwrap();
        let ir = lower_program(&prog);
        let instrs = all_instrs(&ir);
        assert!(!instrs.iter().any(|i| matches!(
            i,
            Instruction::Call { func, .. } if func == "length" || func == "array-length"
        )));
        assert!(
            instrs
                .iter()
                .any(|i| matches!(i, Instruction::Load { ty: Type::I64, .. }))
        );
    }

    #[test]
    fn test_lower_array_length_handles_dynamic_array_from_let() {
        let prog = parse(
            "(define (f [n : i64]) : i64 \
               (array-length (let ([a : (Array i64) (make-array i64 n)]) a)))",
        )
        .unwrap();
        let ir = lower_program(&prog);
        let instrs = all_instrs(&ir);

        assert!(!instrs.iter().any(|i| matches!(
            i,
            Instruction::Call { func, .. } if func == "array-length"
        )));
        assert!(
            instrs
                .iter()
                .any(|i| matches!(i, Instruction::Load { ty: Type::I64, .. }))
        );
    }

    // ------------------------------------------------------------------
    // Bitwise / shift / cast lowering — Issue #46
    // ------------------------------------------------------------------

    /// Find the (single) BinOp in a function's IR, if any.
    fn first_binop(ir: &Program) -> Option<BinOp> {
        ir.functions[0].blocks.iter().find_map(|b| {
            b.instructions.iter().find_map(|i| match i {
                Instruction::BinOp { op, .. } => Some(*op),
                _ => None,
            })
        })
    }

    #[test]
    fn test_lower_bit_and_maps_to_bitand() {
        let prog = parse("(define (f [a : i64] [b : i64]) : i64 (bit-and a b))").unwrap();
        let ir = lower_program(&prog);
        assert_eq!(first_binop(&ir), Some(BinOp::BitAnd));
    }

    #[test]
    fn test_lower_bit_or_maps_to_bitor() {
        let prog = parse("(define (f [a : i64] [b : i64]) : i64 (bit-or a b))").unwrap();
        let ir = lower_program(&prog);
        assert_eq!(first_binop(&ir), Some(BinOp::BitOr));
    }

    #[test]
    fn test_lower_bit_xor_is_not_or() {
        // Miscompile bug 1: bit-xor previously lowered to BinOp::Or.
        let prog = parse("(define (f [a : i64] [b : i64]) : i64 (bit-xor a b))").unwrap();
        let ir = lower_program(&prog);
        let op = first_binop(&ir);
        assert_eq!(op, Some(BinOp::BitXor));
        assert_ne!(op, Some(BinOp::Or), "bit-xor must not lower to Or");
    }

    #[test]
    fn test_lower_shl_is_not_add() {
        // Miscompile bug 2: shl previously lowered to BinOp::Add.
        let prog = parse("(define (f [a : i64] [b : i64]) : i64 (shl a b))").unwrap();
        let ir = lower_program(&prog);
        let op = first_binop(&ir);
        assert_eq!(op, Some(BinOp::Shl));
        assert_ne!(op, Some(BinOp::Add), "shl must not lower to Add");
    }

    #[test]
    fn test_lower_shr_is_not_sub() {
        // shr previously lowered to BinOp::Sub.
        let prog = parse("(define (f [a : i64] [b : i64]) : i64 (shr a b))").unwrap();
        let ir = lower_program(&prog);
        let op = first_binop(&ir);
        assert_eq!(op, Some(BinOp::Shr));
        assert_ne!(op, Some(BinOp::Sub), "shr must not lower to Sub");
    }

    #[test]
    fn test_lower_bit_not_maps_to_bitnot() {
        // bit-not previously lowered to UnOp::Not (boolean). It must now be a
        // distinct one's-complement op preserving the integer width.
        // (Unary ops are not parsed from text yet; build the AST directly.)
        let prog = ast::Program {
            decls: vec![ast::Decl::DefFn {
                name: "f".into(),
                params: vec![("x".into(), Type::I32)],
                ret: Type::I32,
                body: ast::Expr::Unary {
                    op: ast::UnOp::BitNot,
                    expr: Box::new(ast::Expr::Var("x".into())),
                },
            }],
        };
        let ir = lower_program(&prog);
        let unop = ir.functions[0].blocks.iter().find_map(|b| {
            b.instructions.iter().find_map(|i| match i {
                Instruction::UnOp { op, ty, .. } => Some((*op, ty.clone())),
                _ => None,
            })
        });
        assert_eq!(unop, Some((UnOp::BitNot, Type::I32)));
    }

    #[test]
    fn test_lower_binop_width_threaded_from_params() {
        // The BinOp `ty` must reflect the real operand width (u32 here), not the
        // old hard-coded i64 default for var/var operands.
        let prog = parse("(define (f [a : u32] [b : u32]) : u32 (bit-and a b))").unwrap();
        let ir = lower_program(&prog);
        let ty = ir.functions[0].blocks.iter().find_map(|b| {
            b.instructions.iter().find_map(|i| match i {
                Instruction::BinOp { ty, .. } => Some(ty.clone()),
                _ => None,
            })
        });
        assert_eq!(ty, Some(Type::U32));
    }

    #[test]
    fn test_lower_cast_records_target_type_and_from_type() {
        // (cast x : i8) on an i64 parameter lowers to a Cast carrying both the
        // source (i64) and target (i8) types.
        let prog = parse("(define (f [x : i64]) : i8 (cast x : i8))").unwrap();
        let ir = lower_program(&prog);
        let cast = ir.functions[0].blocks.iter().find_map(|b| {
            b.instructions.iter().find_map(|i| match i {
                Instruction::Cast { from_ty, to_ty, .. } => Some((from_ty.clone(), to_ty.clone())),
                _ => None,
            })
        });
        assert_eq!(cast, Some((Type::I64, Type::I8)));
    }

    // ------------------------------------------------------------------
    // Sum types + pattern matching — Issue #41
    // ------------------------------------------------------------------

    fn count<F: Fn(&Instruction) -> bool>(ir: &Program, fn_idx: usize, pred: F) -> usize {
        ir.functions[fn_idx].blocks.iter().fold(0, |acc, b| {
            acc + b.instructions.iter().filter(|i| pred(i)).count()
        })
    }

    const SHAPE: &str = "(defenum Shape (Circle i64) (Square i64) (Nothing))";

    #[test]
    fn test_lower_constructor_emits_alloc_tag_and_payload_store() {
        // (Circle 7) -> Alloc storage, AddrOf base, Gep+Store tag, Gep+Store payload.
        let src = format!("{SHAPE}\n(define (main) : i64 (begin (Circle 7) 0))");
        let prog = parse(&src).unwrap();
        let ir = lower_program(&prog);
        let f = ir.functions.iter().position(|f| f.name == "main").unwrap();

        // One stack-storage Alloc for the enum value.
        let alloc_count = count(&ir, f, |i| matches!(i, Instruction::Alloc { .. }));
        assert_eq!(alloc_count, 1, "expected one storage Alloc");

        // AddrOf to get a pointer to the storage.
        assert_eq!(
            count(&ir, f, |i| matches!(i, Instruction::AddrOf { .. })),
            1
        );

        // Two Geps: tag slot + payload slot.
        assert_eq!(count(&ir, f, |i| matches!(i, Instruction::Gep { .. })), 2);

        // The tag (0 for Circle) is stored as an i64.
        let stores_tag = ir.functions[f].blocks.iter().any(|b| {
            b.instructions.iter().any(|i| {
                matches!(
                    i,
                    Instruction::Store {
                        src: Value::ConstI64(0),
                        ty: Type::I64,
                        ..
                    }
                )
            })
        });
        assert!(stores_tag, "expected a tag Store of ConstI64(0)");

        // The payload value 7 is stored.
        let stores_payload = ir.functions[f].blocks.iter().any(|b| {
            b.instructions.iter().any(|i| {
                matches!(
                    i,
                    Instruction::Store {
                        src: Value::ConstI64(7),
                        ..
                    }
                )
            })
        });
        assert!(stores_payload, "expected a payload Store of ConstI64(7)");
    }

    // ------------------------------------------------------------------
    // Heap promotion of escaping aggregates — refs #13/#45
    // ------------------------------------------------------------------

    #[test]
    fn test_lower_returned_enum_constructor_is_heap_allocated() {
        // When the enclosing function RETURNS the enum, its constructor storage
        // is heap-promoted: a `Call tl_alloc` (sized to the enum) replaces the
        // frame `Alloc` + `AddrOf` pair, so the returned pointer outlives the
        // frame. The tag/payload Stores are unchanged (they go through Geps).
        let src = format!("{SHAPE}\n(define (mk) : Shape (Circle 7))");
        let prog = parse(&src).unwrap();
        let ir = lower_program(&prog);
        let f = ir.functions.iter().position(|f| f.name == "mk").unwrap();

        // No frame Alloc / AddrOf for the storage — it lives on the heap.
        assert_eq!(
            count(&ir, f, |i| matches!(i, Instruction::Alloc { .. })),
            0,
            "escaping enum storage must NOT be a frame Alloc"
        );
        assert_eq!(
            count(&ir, f, |i| matches!(i, Instruction::AddrOf { .. })),
            0,
            "escaping enum storage must NOT take a frame address"
        );

        // Exactly one tl_alloc Call provides the storage, sized to the enum.
        let alloc_calls = ir.functions[f]
            .blocks
            .iter()
            .flat_map(|b| &b.instructions)
            .filter_map(|i| match i {
                Instruction::Call { func, args, .. } if func == "tl_alloc" => Some(args.clone()),
                _ => None,
            })
            .collect::<Vec<_>>();
        assert_eq!(alloc_calls.len(), 1, "expected one storage tl_alloc Call");
        assert_eq!(
            alloc_calls[0],
            vec![Value::ConstI64(16)],
            "expected tl_alloc to request the 16-byte enum storage"
        );

        // Tag (0) and payload (7) are still stored through the (heap) base.
        assert_eq!(count(&ir, f, |i| matches!(i, Instruction::Gep { .. })), 2);
        let stores_payload = ir.functions[f].blocks.iter().any(|b| {
            b.instructions.iter().any(|i| {
                matches!(
                    i,
                    Instruction::Store {
                        src: Value::ConstI64(7),
                        ..
                    }
                )
            })
        });
        assert!(stores_payload, "expected a payload Store of ConstI64(7)");
    }

    #[test]
    fn test_lower_returned_string_is_heap_allocated() {
        // A `String`-returning function heap-promotes the fat-string storage:
        // `Call tl_alloc(16)` instead of a frame Alloc + AddrOf.
        let src = r#"(define (mk) : String "hi")"#;
        let prog = parse(src).unwrap();
        let ir = lower_program(&prog);
        let f = ir.functions.iter().position(|f| f.name == "mk").unwrap();

        assert_eq!(
            count(&ir, f, |i| matches!(i, Instruction::Alloc { .. })),
            0,
            "escaping string storage must NOT be a frame Alloc"
        );
        let has_alloc16 = ir.functions[f].blocks.iter().any(|b| {
            b.instructions.iter().any(|i| {
                matches!(
                    i,
                    Instruction::Call { func, args, .. }
                        if func == "tl_alloc" && args == &[Value::ConstI64(16)]
                )
            })
        });
        assert!(
            has_alloc16,
            "expected tl_alloc(16) for the fat-string storage"
        );
    }

    #[test]
    fn test_lower_returned_enum_payload_string_is_heap_allocated() {
        // Returning an enum with a String payload must promote both pieces:
        // the outer enum storage and the nested fat-string storage. Otherwise
        // the returned heap enum would point at string metadata in this frame.
        let src = r#"
            (defenum Box (Boxed String))
            (define (mk) : Box (Boxed "hi"))
        "#;
        let prog = parse(src).unwrap();
        let ir = lower_program(&prog);
        let f = ir.functions.iter().position(|f| f.name == "mk").unwrap();

        assert_eq!(
            count(&ir, f, |i| matches!(i, Instruction::Alloc { .. })),
            0,
            "escaping enum payload string storage must NOT be a frame Alloc"
        );
        assert_eq!(
            count(&ir, f, |i| matches!(i, Instruction::Call { func, args, .. }
                    if func == "tl_alloc" && args == &[Value::ConstI64(16)])),
            2,
            "expected tl_alloc(16) for both enum storage and string storage"
        );
    }

    #[test]
    fn test_lower_returned_dyn_array_fat_value_is_heap_allocated() {
        // The element buffer was always heap; returning the array additionally
        // heap-promotes the fat `{ ptr, len }` value. So there are TWO tl_alloc
        // Calls (buffer + fat value) and NO frame Alloc for the fat value.
        let src = "(define (mk [n : i64]) : (Array i64) (make-array i64 n))";
        let prog = parse(src).unwrap();
        let ir = lower_program(&prog);
        let f = ir.functions.iter().position(|f| f.name == "mk").unwrap();

        // The only frame Alloc is the parameter slot for `n`; the fat value is
        // NOT a frame Alloc.
        let alloc_count = count(&ir, f, |i| matches!(i, Instruction::Alloc { .. }));
        assert_eq!(
            alloc_count, 1,
            "only the `n` parameter slot should be a frame Alloc (fat value is heap)"
        );

        let tl_alloc_calls = count(
            &ir,
            f,
            |i| matches!(i, Instruction::Call { func, .. } if func == "tl_alloc"),
        );
        assert_eq!(
            tl_alloc_calls, 2,
            "expected two tl_alloc Calls: element buffer + heap-promoted fat value"
        );
        // The fat value's heap request is the 16-byte fat-array storage.
        let has_alloc16 = ir.functions[f].blocks.iter().any(|b| {
            b.instructions.iter().any(|i| {
                matches!(
                    i,
                    Instruction::Call { func, args, .. }
                        if func == "tl_alloc" && args == &[Value::ConstI64(16)]
                )
            })
        });
        assert!(has_alloc16, "expected tl_alloc(16) for the fat-array value");
    }

    #[test]
    fn test_lower_non_escaping_local_aggregate_stays_on_frame() {
        // Selectivity: a function whose return type is NOT an aggregate keeps its
        // local enum constructor on the frame (Alloc + AddrOf), with no tl_alloc.
        let src = format!("{SHAPE}\n(define (main) : i64 (begin (Circle 7) 0))");
        let prog = parse(&src).unwrap();
        let ir = lower_program(&prog);
        let f = ir.functions.iter().position(|f| f.name == "main").unwrap();

        assert_eq!(
            count(&ir, f, |i| matches!(i, Instruction::Alloc { .. })),
            1,
            "non-escaping enum storage stays a frame Alloc"
        );
        assert_eq!(
            count(&ir, f, |i| matches!(i, Instruction::AddrOf { .. })),
            1,
            "non-escaping enum storage takes a frame address"
        );
        assert_eq!(
            count(
                &ir,
                f,
                |i| matches!(i, Instruction::Call { func, .. } if func == "tl_alloc")
            ),
            0,
            "non-escaping enum storage must NOT be heap-allocated"
        );
    }

    #[test]
    fn test_lower_match_emits_tag_load_eq_branch_phi() {
        // A 3-arm match (2 variant arms + nullary) over a 3-variant enum:
        //   - one tag Load
        //   - one Eq + Branch per refutable (variant) arm => 3 Eq, 3 Branch
        //   - exactly one Phi selecting the result
        let src = format!(
            "{SHAPE}\n(define (area [s : Shape]) : i64 \
               (match s [(Circle r) (* r r)] [(Square w) (* w w)] [Nothing 0]))"
        );
        let prog = parse(&src).unwrap();
        let ir = lower_program(&prog);
        let f = ir.functions.iter().position(|f| f.name == "area").unwrap();

        // Tag load (offset 0). There is one Load for the tag plus one per bound
        // payload field (Circle r, Square w) => 3 Loads total.
        let load_count = count(&ir, f, |i| matches!(i, Instruction::Load { .. }));
        assert_eq!(load_count, 3, "expected tag Load + 2 payload Loads");

        // One Eq comparison and one Branch per variant arm (3 of each).
        assert_eq!(
            count(&ir, f, |i| matches!(
                i,
                Instruction::BinOp { op: BinOp::Eq, .. }
            )),
            3,
            "expected one tag-Eq per variant arm"
        );
        assert_eq!(
            count(&ir, f, |i| matches!(i, Instruction::Branch { .. })),
            3,
            "expected one Branch per variant arm"
        );

        // Exactly one Phi merges the arm results.
        assert_eq!(
            count(&ir, f, |i| matches!(i, Instruction::Phi { .. })),
            1,
            "expected one result Phi"
        );
    }

    #[test]
    fn test_lower_match_wildcard_falls_through() {
        // [_ 0] arm: no Eq/Branch for the wildcard; only the Circle arm tests.
        let src = format!(
            "{SHAPE}\n(define (area [s : Shape]) : i64 \
               (match s [(Circle r) r] [_ 0]))"
        );
        let prog = parse(&src).unwrap();
        let ir = lower_program(&prog);
        let f = ir.functions.iter().position(|f| f.name == "area").unwrap();

        assert_eq!(
            count(&ir, f, |i| matches!(
                i,
                Instruction::BinOp { op: BinOp::Eq, .. }
            )),
            1,
            "wildcard arm should not emit a tag comparison"
        );
        assert_eq!(count(&ir, f, |i| matches!(i, Instruction::Phi { .. })), 1);
    }

    #[test]
    fn test_lower_match_no_const_unit_stub() {
        // Regression: match/constructor must not lower to the old ConstUnit stub.
        let src = format!(
            "{SHAPE}\n(define (main) : i64 \
               (match (Circle 1) [(Circle r) r] [_ 0]))"
        );
        let prog = parse(&src).unwrap();
        let ir = lower_program(&prog);
        let f = ir.functions.iter().position(|f| f.name == "main").unwrap();
        let returns_unit = ir.functions[f].blocks.iter().any(|b| {
            b.instructions
                .iter()
                .any(|i| matches!(i, Instruction::Return(Some(Value::ConstUnit))))
        });
        assert!(!returns_unit, "constructor must not return ConstUnit");
    }

    // ------------------------------------------------------------------
    // Literal patterns on scalar scrutinees — extends #41
    // ------------------------------------------------------------------

    #[test]
    fn test_lower_scalar_match_dispatches_without_tag_load() {
        // A scalar match compares the scrutinee value directly: no tag Load,
        // one Eq + Branch per literal arm, one Phi. The wildcard adds neither.
        let src = "(define (f [n : i64]) : i64 (match n [0 10] [1 20] [_ 0]))";
        let prog = parse(src).unwrap();
        let ir = lower_program(&prog);
        let f = ir.functions.iter().position(|f| f.name == "f").unwrap();

        // No Load at all: the scrutinee is a value, not a tagged aggregate.
        assert_eq!(
            count(&ir, f, |i| matches!(i, Instruction::Load { .. })),
            0,
            "scalar match must not load a tag"
        );
        // Two literal arms => two Eq + two Branch; wildcard adds none.
        assert_eq!(
            count(&ir, f, |i| matches!(
                i,
                Instruction::BinOp { op: BinOp::Eq, .. }
            )),
            2,
            "expected one Eq per literal arm"
        );
        assert_eq!(
            count(&ir, f, |i| matches!(i, Instruction::Branch { .. })),
            2,
            "expected one Branch per literal arm"
        );
        assert_eq!(
            count(&ir, f, |i| matches!(i, Instruction::Phi { .. })),
            1,
            "expected one result Phi"
        );
    }

    #[test]
    fn test_lower_scalar_match_compares_literal_constants() {
        // The Eq's rhs must be the literal constant being matched.
        let src = "(define (f [n : i64]) : i64 (match n [42 1] [_ 0]))";
        let prog = parse(src).unwrap();
        let ir = lower_program(&prog);
        let f = ir.functions.iter().position(|f| f.name == "f").unwrap();
        let cmp_const_42 = ir.functions[f].blocks.iter().any(|b| {
            b.instructions.iter().any(|i| {
                matches!(
                    i,
                    Instruction::BinOp {
                        op: BinOp::Eq,
                        rhs: Value::ConstI64(42),
                        ..
                    }
                )
            })
        });
        assert!(cmp_const_42, "expected an Eq against ConstI64(42)");
    }

    #[test]
    fn test_lower_scalar_wildcard_only_match_does_not_load_tag() {
        // Regression: a scalar match with only `_` has no literal arm, but it is
        // still scalar and must not lower as an enum tag load from the integer.
        let src = "(define (f [n : i64]) : i64 (match n [_ 0]))";
        let prog = parse(src).unwrap();
        let ir = lower_program(&prog);
        let f = ir.functions.iter().position(|f| f.name == "f").unwrap();

        assert_eq!(
            count(&ir, f, |i| matches!(i, Instruction::Load { .. })),
            0,
            "wildcard-only scalar match must not load a tag"
        );
        assert_eq!(
            count(&ir, f, |i| matches!(i, Instruction::Gep { .. })),
            0,
            "wildcard-only scalar match must not compute a tag pointer"
        );
    }

    // ------------------------------------------------------------------
    // Structs / records — Issue #18
    // ------------------------------------------------------------------

    const POINT: &str = "(defstruct Point (x i64) (y i64))";

    #[test]
    fn test_struct_registry_layout() {
        // Point { x:i64, y:i64 }: fields at offsets 0 and 8, total 16 bytes (no
        // tag word, unlike an enum).
        let prog = parse(POINT).unwrap();
        let reg = ast::StructRegistry::from_program(&prog);
        let fields = reg.fields("Point").unwrap();
        let offsets = reg.field_offsets(fields);
        assert_eq!(offsets, vec![0, 8]);
        assert_eq!(reg.struct_size("Point"), 16);
        assert_eq!(reg.lookup_field("Point", "y").map(|(i, _)| i), Some(1));
    }

    #[test]
    fn test_struct_registry_mixed_alignment() {
        // { a:i8, b:i64 }: b is 8-aligned, so a is at 0 and b at 8; size 16.
        let prog = parse("(defstruct M (a i8) (b i64))").unwrap();
        let reg = ast::StructRegistry::from_program(&prog);
        let fields = reg.fields("M").unwrap();
        assert_eq!(reg.field_offsets(fields), vec![0, 8]);
        assert_eq!(reg.struct_size("M"), 16);
    }

    #[test]
    fn test_lower_struct_construct_emits_storage_and_field_stores() {
        // (Point 3 4) in a non-returning position -> a frame Alloc + AddrOf for
        // the 16-byte storage, two Geps (one per field) and two field Stores. No
        // tag store (a struct has no tag).
        let src = format!("{POINT}\n(define (main) : i64 (begin (Point 3 4) 0))");
        let prog = parse(&src).unwrap();
        let ir = lower_program(&prog);
        let f = ir.functions.iter().position(|f| f.name == "main").unwrap();

        // One stack-storage Alloc, sized to the 16-byte struct.
        assert!(
            ir.functions[f]
                .blocks
                .iter()
                .any(|b| b.instructions.iter().any(|i| matches!(
                    i,
                    Instruction::Alloc { ty: Type::Array(elem, 16), .. } if **elem == Type::I8
                ))),
            "expected a 16-byte storage Alloc"
        );
        assert_eq!(
            count(&ir, f, |i| matches!(i, Instruction::AddrOf { .. })),
            1
        );
        // Two field Geps (x at 0, y at 8) — no tag Gep.
        assert_eq!(count(&ir, f, |i| matches!(i, Instruction::Gep { .. })), 2);

        // Both field values are stored as i64.
        for v in [3i64, 4i64] {
            assert!(
                ir.functions[f]
                    .blocks
                    .iter()
                    .any(|b| b.instructions.iter().any(|i| matches!(
                        i,
                        Instruction::Store { src: Value::ConstI64(c), ty: Type::I64, .. } if *c == v
                    ))),
                "expected a field Store of ConstI64({})",
                v
            );
        }
    }

    #[test]
    fn test_lower_struct_get_emits_gep_and_load_at_offset() {
        // `(struct-get p y)` reads field y (offset 8): a Gep to byte offset 8
        // over the struct pointer, then an i64 Load.
        let src = format!("{POINT}\n(define (gety [p : Point]) : i64 (struct-get p y))");
        let prog = parse(&src).unwrap();
        let ir = lower_program(&prog);
        let f = ir.functions.iter().position(|f| f.name == "gety").unwrap();

        // A Gep to the field's byte offset (8).
        assert!(
            ir.functions[f]
                .blocks
                .iter()
                .any(|b| b.instructions.iter().any(|i| matches!(
                    i,
                    Instruction::Gep {
                        offset: Value::ConstI64(8),
                        ..
                    }
                ))),
            "expected a Gep to byte offset 8 for field y"
        );
        // An i64 Load of the field.
        assert!(
            ir.functions[f].blocks.iter().any(|b| b
                .instructions
                .iter()
                .any(|i| matches!(i, Instruction::Load { ty: Type::I64, .. }))),
            "expected an i64 Load of the field"
        );
    }

    #[test]
    fn test_lower_struct_get_first_field_at_offset_zero() {
        // Field x is the first field, at offset 0 (no tag word).
        let src = format!("{POINT}\n(define (getx [p : Point]) : i64 (struct-get p x))");
        let prog = parse(&src).unwrap();
        let ir = lower_program(&prog);
        let f = ir.functions.iter().position(|f| f.name == "getx").unwrap();
        assert!(
            ir.functions[f]
                .blocks
                .iter()
                .any(|b| b.instructions.iter().any(|i| matches!(
                    i,
                    Instruction::Gep {
                        offset: Value::ConstI64(0),
                        ..
                    }
                ))),
            "expected a Gep to byte offset 0 for the first field"
        );
    }

    #[test]
    fn test_lower_struct_layout_resolves_nominal_field_types() {
        // The field type `Inner` parses as a nominal type name; layout must
        // resolve it to pointer-sized `Type::Struct`, not call size/align on the
        // raw parser variable.
        let src = "(defstruct Inner (a i64))\n\
                   (defstruct Outer (inner Inner) (b i64))\n\
                   (define (getb [o : Outer]) : i64 (struct-get o b))";
        let prog = parse(src).unwrap();
        let ir = lower_program(&prog);
        let f = ir.functions.iter().position(|f| f.name == "getb").unwrap();
        assert!(
            ir.functions[f]
                .blocks
                .iter()
                .any(|b| b.instructions.iter().any(|i| matches!(
                    i,
                    Instruction::Gep {
                        offset: Value::ConstI64(8),
                        ..
                    }
                ))),
            "expected field b after the pointer-sized Inner field"
        );
    }

    #[test]
    fn test_lower_returned_struct_is_heap_allocated() {
        // When the enclosing function RETURNS the struct, its constructor
        // storage is heap-promoted: a `Call tl_alloc` replaces the frame Alloc +
        // AddrOf pair so the returned pointer outlives the frame (#85).
        let src = format!("{POINT}\n(define (mk) : Point (Point 1 2))");
        let prog = parse(&src).unwrap();
        let ir = lower_program(&prog);
        let f = ir.functions.iter().position(|f| f.name == "mk").unwrap();

        assert_eq!(
            count(&ir, f, |i| matches!(i, Instruction::Alloc { .. })),
            0,
            "escaping struct storage must NOT be a frame Alloc"
        );
        assert_eq!(
            count(&ir, f, |i| matches!(i, Instruction::AddrOf { .. })),
            0,
            "escaping struct storage must NOT take a frame address"
        );
        let alloc_calls = ir.functions[f]
            .blocks
            .iter()
            .flat_map(|b| &b.instructions)
            .filter(|i| matches!(i, Instruction::Call { func, .. } if func == "tl_alloc"))
            .count();
        assert_eq!(alloc_calls, 1, "expected one storage tl_alloc Call");
    }
}
