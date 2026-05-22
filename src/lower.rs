use crate::ast;
use crate::ir::*;
use crate::types::Type;
use std::collections::HashMap;

/// Lowers a typed AST program into IR.
pub fn lower_program(prog: &ast::Program) -> Program {
    let mut lowerer = ProgramLowerer::new();
    lowerer.lower(prog)
}

struct ProgramLowerer {
    functions: Vec<Function>,
    globals: Vec<(String, Type, Option<Value>)>,
    externs: Vec<(String, Type)>,
    function_types: HashMap<String, Type>,
    enums: ast::EnumRegistry,
}

impl ProgramLowerer {
    fn new() -> Self {
        ProgramLowerer {
            functions: Vec::new(),
            globals: Vec::new(),
            externs: Vec::new(),
            function_types: HashMap::new(),
            enums: ast::EnumRegistry::default(),
        }
    }

    fn lower(&mut self, prog: &ast::Program) -> Program {
        self.enums = ast::EnumRegistry::from_program(prog);

        for decl in &prog.decls {
            match decl {
                ast::Decl::DefFn {
                    name, params, ret, ..
                } => {
                    self.function_types.insert(
                        name.clone(),
                        Type::Func(
                            params
                                .iter()
                                .map(|(_, ty)| self.enums.resolve_type(ty))
                                .collect(),
                            Box::new(self.enums.resolve_type(ret)),
                        ),
                    );
                }
                ast::Decl::Extern { name, ty } => {
                    self.function_types
                        .insert(name.clone(), self.enums.resolve_type(ty));
                }
                ast::Decl::Def { .. } | ast::Decl::DefEnum { .. } => {}
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
                        &self.enums,
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
                        .map(|(n, t)| (n.clone(), self.enums.resolve_type(t)))
                        .collect();
                    let ret = self.enums.resolve_type(ret);
                    let func = self.lower_function(name, &params, &ret, body);
                    self.functions.push(func);
                }
                ast::Decl::Extern { name, ty } => {
                    self.externs
                        .push((name.clone(), self.enums.resolve_type(ty)));
                }
                ast::Decl::DefEnum { .. } => {}
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
        let fn_lowerer = FnLowerer::new(name, params, ret, &self.function_types, &self.enums);
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
        ast::Expr::Literal(ast::Literal::String(_)) => Type::Var("String".into()),
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
    function_types: HashMap<String, Type>,
    enums: ast::EnumRegistry,
    params: Vec<(VarId, Type)>,
    locals: Vec<(VarId, Type)>,
    #[allow(dead_code)]
    ret: Type,
}

impl FnLowerer {
    fn new(
        name: &str,
        params: &[(String, Type)],
        ret: &Type,
        function_types: &HashMap<String, Type>,
        enums: &ast::EnumRegistry,
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
            function_types: function_types.clone(),
            enums: enums.clone(),
            params: ir_params,
            locals: Vec::new(),
            ret: ret.clone(),
        }
    }

    /// Lower a function body and produce a complete IR Function.
    fn lower_body(mut self, body: &ast::Expr, ret_ty: &Type) -> Function {
        let result = self.lower_expr(body);
        self.builder.emit(Instruction::Return(Some(result)));

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
            // Tuple, Array, Lambda — stubbed to unit for now
            ast::Expr::Tuple(_) | ast::Expr::Array(_) | ast::Expr::Lambda { .. } => {
                Value::ConstUnit
            }
            ast::Expr::TupleRef { .. } | ast::Expr::ArrayRef { .. } => Value::ConstUnit,
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
            let binding_ty = ty.clone().unwrap_or_else(|| self.value_type(&val));

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

        // Evaluate arguments left-to-right
        let arg_vals: Vec<Value> = args.iter().map(|a| self.lower_expr(a)).collect();

        let (func_name, ret_ty) = match func.unspan() {
            ast::Expr::Var(name) => {
                let ret_ty = match self.function_types.get(name) {
                    Some(Type::Func(_, ret)) => (**ret).clone(),
                    _ => Type::Unit,
                };
                (name.clone(), ret_ty)
            }
            _ => {
                // Indirect call through expression
                let func_val = self.lower_expr(func);
                let dst = self.builder.fresh_var();
                self.builder.emit(Instruction::CallIndirect {
                    dst: Some(dst),
                    func: func_val,
                    args: arg_vals,
                    ty: Type::Unit,
                });
                self.record_local(dst, Type::Unit);
                return Value::Var(dst);
            }
        };

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

    /// Construct an enum value: reserve inline `{ tag, payload }` storage,
    /// store the variant tag, store each payload field at its byte offset, and
    /// yield a pointer to the storage (the runtime representation of an enum
    /// value). Uses only Alloc/AddrOf/Gep/Store — no new IR.
    fn lower_construct(&mut self, enum_name: &str, tag: usize, args: &[Value]) -> Value {
        let size = self.enums.enum_size(enum_name);
        let enum_ty = Type::Enum(enum_name.to_string());

        // Reserve `size` bytes of inline storage as an i8 array (align 1, exact
        // size) so the backend allocates the right number of bytes.
        let slot = self.builder.fresh_var();
        let storage_ty = Type::Array(Box::new(Type::I8), size);
        self.builder.emit(Instruction::Alloc {
            var: slot,
            ty: storage_ty.clone(),
        });
        self.record_local(slot, storage_ty);

        // base = &slot : pointer to the storage.
        let base = self.builder.fresh_var();
        self.builder.emit(Instruction::AddrOf {
            dst: base,
            src: slot,
        });
        self.record_local(base, enum_ty.clone());
        let base_val = Value::Var(base);

        // Store the tag at offset 0.
        let tag_ptr = self.gep_byte(&base_val, 0);
        self.builder.emit(Instruction::Store {
            dst: Value::Var(tag_ptr),
            src: Value::ConstI64(tag as i64),
            ty: Type::I64,
        });

        // Store each payload field at its (resolved) byte offset.
        let raw_fields: Vec<Type> = self.enums.lookup_variant_fields(enum_name, tag).to_vec();
        let field_tys: Vec<Type> = raw_fields
            .iter()
            .map(|t| self.enums.resolve_type(t))
            .collect();
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
    /// template: load the scrutinee's tag, then for each variant arm emit a
    /// tag-equality `Eq` plus a `Branch`, binding payload fields via `Gep` and
    /// `Load` in the matched arm. A `Phi` in the merge block selects the arm
    /// result. A wildcard arm becomes the final fall-through.
    fn lower_match(&mut self, scrutinee: &ast::Expr, arms: &[(ast::Pattern, ast::Expr)]) -> Value {
        let scrut = self.lower_expr(scrutinee);

        // Load the tag (offset 0).
        let tag_ptr = self.gep_byte(&scrut, 0);
        let tag_val = self.builder.fresh_var();
        self.builder.emit(Instruction::Load {
            dst: tag_val,
            src: Value::Var(tag_ptr),
            ty: Type::I64,
        });
        self.record_local(tag_val, Type::I64);

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
                    let field_tys: Vec<Type> = raw_fields
                        .iter()
                        .map(|t| self.enums.resolve_type(t))
                        .collect();
                    let offsets = self.enums.field_offsets(&field_tys);

                    let arm_label = self.builder.fresh_label("match_arm");
                    let next_label = self.builder.fresh_label("match_next");

                    // tag == this_tag ?
                    let cmp = self.builder.fresh_var();
                    self.builder.emit(Instruction::BinOp {
                        dst: cmp,
                        op: BinOp::Eq,
                        lhs: Value::Var(tag_val),
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
                _ => {
                    // Other patterns are rejected by the typechecker.
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
            Value::Var(v) => self.var_types.get(v).cloned().unwrap_or(Type::I64),
            Value::Global(_) => Type::I64,
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
    fn test_lower_string_literal_stub() {
        // String literals are not yet supported in IR; lowerer returns ConstUnit.
        let prog = parse(
            r#"
            (define (get_str) : i64 "hello")
        "#,
        )
        .unwrap();
        let ir = lower_program(&prog);
        assert_eq!(ir.functions.len(), 1);

        let has_unit_return = ir.functions[0].blocks.iter().any(|b| {
            b.instructions.iter().any(|i| {
                if let Instruction::Return(Some(Value::ConstUnit)) = i {
                    true
                } else {
                    false
                }
            })
        });
        assert!(has_unit_return);
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
        let src = format!("{SHAPE}\n(define (mk) : Shape (Circle 7))");
        let prog = parse(&src).unwrap();
        let ir = lower_program(&prog);
        let f = ir.functions.iter().position(|f| f.name == "mk").unwrap();

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
        let src = format!("{SHAPE}\n(define (mk) : Shape (Circle 1))");
        let prog = parse(&src).unwrap();
        let ir = lower_program(&prog);
        let f = ir.functions.iter().position(|f| f.name == "mk").unwrap();
        let returns_unit = ir.functions[f].blocks.iter().any(|b| {
            b.instructions
                .iter()
                .any(|i| matches!(i, Instruction::Return(Some(Value::ConstUnit))))
        });
        assert!(!returns_unit, "constructor must not return ConstUnit");
    }
}
