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
}

impl ProgramLowerer {
    fn new() -> Self {
        ProgramLowerer {
            functions: Vec::new(),
            globals: Vec::new(),
            externs: Vec::new(),
        }
    }

    fn lower(&mut self, prog: &ast::Program) -> Program {
        for decl in &prog.decls {
            match decl {
                ast::Decl::Def { name, ty, value } => {
                    let val_ty = ty.clone().unwrap_or_else(|| infer_literal_type(value));
                    // Lower the global initializer as an anonymous function
                    let fn_lowerer = FnLowerer::new("__global_init", &[], &val_ty);
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
                    let func = self.lower_function(name, params, ret, body);
                    self.functions.push(func);
                }
                ast::Decl::Extern { name, ty } => {
                    self.externs.push((name.clone(), ty.clone()));
                }
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
        let fn_lowerer = FnLowerer::new(name, params, ret);
        fn_lowerer.lower_body(body, ret)
    }
}

/// Infers the type of a literal expression for use in global initializers.
fn infer_literal_type(expr: &ast::Expr) -> Type {
    match expr {
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
    match expr {
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
    params: Vec<(VarId, Type)>,
    locals: Vec<(VarId, Type)>,
    #[allow(dead_code)]
    ret: Type,
}

impl FnLowerer {
    fn new(name: &str, params: &[(String, Type)], ret: &Type) -> Self {
        let mut builder = IrBuilder::new("entry");
        let mut vars = HashMap::new();
        let mut ir_params = Vec::new();

        for (param_name, param_ty) in params {
            let var = builder.fresh_var();
            builder.emit(Instruction::Alloc {
                var,
                ty: param_ty.clone(),
            });
            ir_params.push((var, param_ty.clone()));
            vars.insert(param_name.clone(), var);
        }

        FnLowerer {
            name: name.to_string(),
            builder,
            vars,
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
        match expr {
            ast::Expr::Literal(lit) => self.lower_literal(lit),
            ast::Expr::Var(name) => self.lower_var(name),
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
            ast::Expr::Set(name, expr) => self.lower_set(name, expr),
            ast::Expr::Ann { expr, .. } => self.lower_expr(expr),
            // Tuple, Array, Lambda — stubbed to unit for now
            ast::Expr::Tuple(_) | ast::Expr::Array(_) | ast::Expr::Lambda { .. } => {
                Value::ConstUnit
            }
            ast::Expr::TupleRef { .. } | ast::Expr::ArrayRef { .. } => Value::ConstUnit,
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

        // Infer the result type from the operands
        let ty = match (&lhs_val, &rhs_val) {
            (Value::ConstI64(_), _) | (_, Value::ConstI64(_)) => Type::I64,
            (Value::ConstF64(_), _) | (_, Value::ConstF64(_)) => Type::F64,
            (Value::ConstI32(_), _) | (_, Value::ConstI32(_)) => Type::I32,
            (Value::ConstBool(_), _) | (_, Value::ConstBool(_)) => Type::Bool,
            _ => Type::I64, // Default
        };

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
            ast::BinOp::BitAnd => BinOp::And,
            ast::BinOp::BitOr => BinOp::Or,
            ast::BinOp::BitXor => BinOp::Or,
            ast::BinOp::Shl => BinOp::Add,
            ast::BinOp::Shr => BinOp::Sub,
        };

        let dst = self.builder.fresh_var();
        self.builder.emit(Instruction::BinOp {
            dst,
            op: ir_op,
            lhs: lhs_val,
            rhs: rhs_val,
            ty: ty.clone(),
        });
        self.locals.push((dst, ty));
        Value::Var(dst)
    }

    fn lower_unary(&mut self, op: ast::UnOp, expr: &ast::Expr) -> Value {
        let src = self.lower_expr(expr);
        let (ir_op, ty) = match op {
            ast::UnOp::Neg => (UnOp::Neg, Type::I64),
            ast::UnOp::Not => (UnOp::Not, Type::Bool),
            ast::UnOp::BitNot => (UnOp::Not, Type::I64),
        };
        let dst = self.builder.fresh_var();
        self.builder.emit(Instruction::UnOp {
            dst,
            op: ir_op,
            src,
            ty: ty.clone(),
        });
        self.locals.push((dst, ty));
        Value::Var(dst)
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
        let result_ty = self.infer_type(&then_val); // Assume branches match (type-checked)
        let phi_dst = self.builder.fresh_var();
        self.builder.emit(Instruction::Phi {
            dst: phi_dst,
            incoming: vec![
                (then_val, then_label.clone()),
                (else_val, else_label.clone()),
            ],
            ty: result_ty.clone(),
        });
        self.locals.push((phi_dst, result_ty));
        Value::Var(phi_dst)
    }

    fn lower_let(
        &mut self,
        bindings: &[(String, Option<Type>, ast::Expr)],
        body: &ast::Expr,
    ) -> Value {
        for (name, ty, value) in bindings {
            let val = self.lower_expr(value);
            let binding_ty = ty.clone().unwrap_or_else(|| self.infer_type(&val));

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
            self.locals.push((var, binding_ty));
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
        // Evaluate arguments left-to-right
        let arg_vals: Vec<Value> = args.iter().map(|a| self.lower_expr(a)).collect();

        let (func_name, ret_ty) = match func {
            ast::Expr::Var(name) => (name.clone(), Type::Unit),
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
                self.locals.push((dst, Type::Unit));
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
        self.locals.push((dst, ret_ty));
        Value::Var(dst)
    }

    fn lower_set(&mut self, name: &str, expr: &ast::Expr) -> Value {
        let val = self.lower_expr(expr);
        if let Some(&var) = self.vars.get(name) {
            let ty = self.infer_type(&val);
            self.builder.emit(Instruction::Store {
                dst: Value::Var(var),
                src: val,
                ty,
            });
        }
        Value::ConstUnit
    }

    /// Infer the Type of a Value. Only works for constants; defaults to I64 for Vars.
    fn infer_type(&self, val: &Value) -> Type {
        match val {
            Value::ConstI64(_) => Type::I64,
            Value::ConstI32(_) => Type::I32,
            Value::ConstI8(_) => Type::I8,
            Value::ConstF64(_) => Type::F64,
            Value::ConstBool(_) => Type::Bool,
            Value::ConstUnit => Type::Unit,
            Value::Var(_) => Type::I64, // Default, could be refined
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
    use crate::parser::parse;

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
}
