use crate::ast;
use crate::ir;
use crate::ir::{IrBuilder, Value, Instruction, Function, Program, VarId};
use crate::types::Type;
use std::collections::HashMap;

/// Lower a typed AST program to IR
pub fn lower_program(prog: &ast::Program) -> Program {
    let mut functions = Vec::new();
    let mut globals = Vec::new();
    let mut externs = Vec::new();

    for decl in &prog.decls {
        match decl {
            ast::Decl::DefFn { name, params, ret, body } => {
                let func = lower_function(name, params, ret.clone(), body);
                functions.push(func);
            }
            ast::Decl::Def { name, ty, value } => {
                // For globals, just lower the value expression to a constant if possible
                // For now, create a global with its type and a lowered value
                let global_ty = ty.clone().unwrap_or_else(|| infer_expr_type(value));
                let init = lower_global_value(value);
                globals.push((name.clone(), global_ty, init));
            }
            ast::Decl::Extern { name, ty } => {
                externs.push((name.clone(), ty.clone()));
            }
        }
    }

    Program { functions, globals, externs }
}

/// Infer a rough type for an expression (used for globals when type isn't annotated)
fn infer_expr_type(expr: &ast::Expr) -> Type {
    match expr {
        ast::Expr::Literal(lit) => match lit {
            ast::Literal::Int(_) => Type::I64,
            ast::Literal::Float(_) => Type::F64,
            ast::Literal::Bool(_) => Type::Bool,
            ast::Literal::Char(_) => Type::Char,
            ast::Literal::String(_) => Type::Var("String".into()),
            ast::Literal::Unit => Type::Unit,
        },
        _ => Type::I64, // default fallback
    }
}

/// Try to lower a global value to a constant Value, or None if not a simple constant
fn lower_global_value(expr: &ast::Expr) -> Option<Value> {
    match expr {
        ast::Expr::Literal(lit) => match lit {
            ast::Literal::Int(n) => Some(Value::ConstI64(*n)),
            ast::Literal::Bool(b) => Some(Value::ConstBool(*b)),
            ast::Literal::Unit => Some(Value::ConstUnit),
            _ => None,
        },
        _ => None,
    }
}

/// Lower a function definition to IR
fn lower_function(
    name: &str,
    params: &[(ast::Symbol, Type)],
    ret: Type,
    body: &ast::Expr,
) -> Function {
    let mut builder = IrBuilder::new("entry");
    let mut env: HashMap<String, VarId> = HashMap::new();
    let mut ir_params = Vec::new();
    let mut locals = Vec::new();

    // Create Alloc for each parameter, map param name to the alloc'd var
    for (param_name, param_ty) in params {
        let var = builder.fresh_var();
        builder.emit(Instruction::Alloc { var, ty: param_ty.clone() });
        env.insert(param_name.clone(), var);
        ir_params.push((var, param_ty.clone()));
        locals.push((var, param_ty.clone()));
    }

    // Lower the body expression
    let result = lower_expr(body, &mut builder, &mut env, &mut locals);

    // Emit return
    builder.emit(Instruction::Return(Some(Value::Var(result))));

    let blocks = builder.build();

    Function {
        name: name.to_string(),
        params: ir_params,
        ret,
        locals,
        blocks,
        entry: "entry".into(),
    }
}

/// Lower an expression to IR, returning the VarId that holds the result
fn lower_expr(
    expr: &ast::Expr,
    builder: &mut IrBuilder,
    env: &mut HashMap<String, VarId>,
    locals: &mut Vec<(VarId, Type)>,
) -> VarId {
    match expr {
        ast::Expr::Literal(lit) => {
            let dst = builder.fresh_var();
            let (val, ty) = match lit {
                ast::Literal::Int(n) => (Value::ConstI64(*n), Type::I64),
                ast::Literal::Bool(b) => (Value::ConstBool(*b), Type::Bool),
                ast::Literal::Float(_) => {
                    // Not implemented in this basic lowering
                    todo!("float literal lowering")
                }
                ast::Literal::Char(_) => {
                    todo!("char literal lowering")
                }
                ast::Literal::String(_) => {
                    todo!("string literal lowering")
                }
                ast::Literal::Unit => (Value::ConstUnit, Type::Unit),
            };
            builder.emit(Instruction::Mov { dst, src: val, ty });
            locals.push((dst, infer_literal_type(lit)));
            dst
        }
        ast::Expr::Var(name) => {
            let src = *env.get(name).expect(&format!("unbound variable: {}", name));
            let dst = builder.fresh_var();
            // We don't know the exact type here, so use I64 as default for Var lookups
            // In a fully typed lowering, we'd carry type info through the AST
            let ty = Type::I64;
            builder.emit(Instruction::Mov { dst, src: Value::Var(src), ty: ty.clone() });
            locals.push((dst, ty));
            dst
        }
        ast::Expr::Binary { op, lhs, rhs } => {
            let l = lower_expr(lhs, builder, env, locals);
            let r = lower_expr(rhs, builder, env, locals);
            let dst = builder.fresh_var();
            let (ir_op, ty) = map_binop(op);
            builder.emit(Instruction::BinOp {
                dst,
                op: ir_op,
                lhs: Value::Var(l),
                rhs: Value::Var(r),
                ty: ty.clone(),
            });
            locals.push((dst, ty));
            dst
        }
        ast::Expr::If { cond, then_branch, else_branch } => {
            let cond_var = lower_expr(cond, builder, env, locals);
            let dst = builder.fresh_var();
            let ty = Type::I64; // We could try to infer, but default to I64 for now

            let true_label = builder.fresh_label("then");
            let false_label = builder.fresh_label("else");
            let merge_label = builder.fresh_label("merge");

            builder.emit(Instruction::Branch {
                cond: Value::Var(cond_var),
                true_label: true_label.clone(),
                false_label: false_label.clone(),
            });

            // Then block
            builder.finish_block(&true_label);
            let then_var = lower_expr(then_branch, builder, env, locals);
            builder.emit(Instruction::Mov { dst, src: Value::Var(then_var), ty: ty.clone() });
            builder.emit(Instruction::Jump(merge_label.clone()));

            // Else block
            builder.finish_block(&false_label);
            let else_var = lower_expr(else_branch, builder, env, locals);
            builder.emit(Instruction::Mov { dst, src: Value::Var(else_var), ty: ty.clone() });
            builder.emit(Instruction::Jump(merge_label.clone()));

            // Merge block
            builder.finish_block(&merge_label);
            locals.push((dst, ty));
            dst
        }
        ast::Expr::Call { func, args } => {
            // Extract function name from Var
            let func_name = match func.as_ref() {
                ast::Expr::Var(name) => name.clone(),
                _ => todo!("indirect call lowering not yet implemented"),
            };

            let mut arg_vars = Vec::new();
            for arg in args {
                let v = lower_expr(arg, builder, env, locals);
                arg_vars.push(Value::Var(v));
            }

            let dst = builder.fresh_var();
            let ty = Type::I64; // Default return type
            builder.emit(Instruction::Call {
                dst: Some(dst),
                func: func_name,
                args: arg_vars,
                ty: ty.clone(),
            });
            locals.push((dst, ty));
            dst
        }
        ast::Expr::Unary { .. } => {
            todo!("unary expression lowering")
        }
        ast::Expr::Let { .. } => {
            todo!("let expression lowering")
        }
        ast::Expr::Lambda { .. } => {
            todo!("lambda expression lowering")
        }
        ast::Expr::Tuple(_) | ast::Expr::TupleRef { .. } => {
            todo!("tuple expression lowering")
        }
        ast::Expr::Array(_) | ast::Expr::ArrayRef { .. } => {
            todo!("array expression lowering")
        }
        ast::Expr::While { .. } => {
            todo!("while expression lowering")
        }
        ast::Expr::Begin(_) => {
            todo!("begin expression lowering")
        }
        ast::Expr::Set(_, _) => {
            todo!("set! expression lowering")
        }
        ast::Expr::Ann { expr, .. } => {
            // Ignore annotation, lower the underlying expression
            lower_expr(expr, builder, env, locals)
        }
    }
}

fn infer_literal_type(lit: &ast::Literal) -> Type {
    match lit {
        ast::Literal::Int(_) => Type::I64,
        ast::Literal::Float(_) => Type::F64,
        ast::Literal::Bool(_) => Type::Bool,
        ast::Literal::Char(_) => Type::Char,
        ast::Literal::String(_) => Type::Var("String".into()),
        ast::Literal::Unit => Type::Unit,
    }
}

fn map_binop(op: &ast::BinOp) -> (ir::BinOp, Type) {
    match op {
        ast::BinOp::Add => (ir::BinOp::Add, Type::I64),
        ast::BinOp::Sub => (ir::BinOp::Sub, Type::I64),
        ast::BinOp::Mul => (ir::BinOp::Mul, Type::I64),
        ast::BinOp::Div => (ir::BinOp::Div, Type::I64),
        ast::BinOp::Mod => (ir::BinOp::Mod, Type::I64),
        ast::BinOp::Eq => (ir::BinOp::Eq, Type::Bool),
        ast::BinOp::Ne => (ir::BinOp::Ne, Type::Bool),
        ast::BinOp::Lt => (ir::BinOp::Lt, Type::Bool),
        ast::BinOp::Le => (ir::BinOp::Le, Type::Bool),
        ast::BinOp::Gt => (ir::BinOp::Gt, Type::Bool),
        ast::BinOp::Ge => (ir::BinOp::Ge, Type::Bool),
        ast::BinOp::And => (ir::BinOp::And, Type::Bool),
        ast::BinOp::Or => (ir::BinOp::Or, Type::Bool),
        ast::BinOp::BitAnd => (ir::BinOp::And, Type::I64),
        ast::BinOp::BitOr => (ir::BinOp::Or, Type::I64),
        ast::BinOp::BitXor => todo!("bit-xor lowering"),
        ast::BinOp::Shl => todo!("shl lowering"),
        ast::BinOp::Shr => todo!("shr lowering"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ast::{Expr, Literal, BinOp as AstBinOp};
    use crate::ir::{Instruction, Value};

    #[test]
    fn test_lower_simple_add() {
        // Build AST for (+ 1 2)
        let body = Expr::Binary {
            op: AstBinOp::Add,
            lhs: Box::new(Expr::Literal(Literal::Int(1))),
            rhs: Box::new(Expr::Literal(Literal::Int(2))),
        };
        let params: Vec<(String, Type)> = vec![];
        let func = lower_function("main", &params, Type::I64, &body);

        assert_eq!(func.name, "main");
        assert_eq!(func.params.len(), 0);
        assert_eq!(func.ret, Type::I64);
        assert_eq!(func.blocks.len(), 1);

        let entry = &func.blocks[0];
        assert_eq!(entry.label, "entry");
        // Expected: Alloc (none), Mov(1), Mov(2), BinOp, Return
        let instrs = &entry.instructions;
        assert!(matches!(&instrs[instrs.len()-2], Instruction::BinOp { .. }), "expected BinOp");
        assert!(matches!(&instrs[instrs.len()-1], Instruction::Return(_)), "expected Return");
    }

    #[test]
    fn test_lower_program_with_function() {
        let ast_prog = ast::Program {
            decls: vec![
                ast::Decl::DefFn {
                    name: "add1".into(),
                    params: vec![("x".into(), Type::I64)],
                    ret: Type::I64,
                    body: Expr::Binary {
                        op: AstBinOp::Add,
                        lhs: Box::new(Expr::Var("x".into())),
                        rhs: Box::new(Expr::Literal(Literal::Int(1))),
                    },
                }
            ]
        };

        let ir_prog = lower_program(&ast_prog);
        assert_eq!(ir_prog.functions.len(), 1);
        assert_eq!(ir_prog.functions[0].name, "add1");
        assert_eq!(ir_prog.globals.len(), 0);
        assert_eq!(ir_prog.externs.len(), 0);
    }

    #[test]
    fn test_lower_bool_literal() {
        let body = Expr::Literal(Literal::Bool(true));
        let func = lower_function("main", &[], Type::Bool, &body);
        let entry = &func.blocks[0];
        let instrs = &entry.instructions;
        assert!(matches!(
            &instrs[0],
            Instruction::Mov { src: Value::ConstBool(true), .. }
        ), "expected Mov from ConstBool(true)");
    }

    #[test]
    fn test_lower_if() {
        let body = Expr::If {
            cond: Box::new(Expr::Literal(Literal::Bool(true))),
            then_branch: Box::new(Expr::Literal(Literal::Int(42))),
            else_branch: Box::new(Expr::Literal(Literal::Int(0))),
        };
        let func = lower_function("main", &[], Type::I64, &body);
        // Should have entry + then + else + merge = 4 blocks
        assert_eq!(func.blocks.len(), 4);

        let entry = &func.blocks[0];
        assert!(matches!(&entry.instructions[entry.instructions.len()-1], Instruction::Branch { .. }));
    }
}
