use crate::ast::*;
use crate::types::Type;
use std::collections::HashMap;
use std::fmt;

#[derive(Debug, Clone)]
pub struct TypeError {
    pub msg: String,
}

impl fmt::Display for TypeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "type error: {}", self.msg)
    }
}

pub struct TypeChecker {
    env: Vec<HashMap<String, Type>>,
    func_ret: Option<Type>,
}

impl TypeChecker {
    pub fn new() -> Self {
        let mut globals = HashMap::new();
        // Built-in externals
        globals.insert("print".into(), Type::Func(vec![Type::I64], Box::new(Type::Unit)));
        globals.insert("print-bool".into(), Type::Func(vec![Type::Bool], Box::new(Type::Unit)));
        globals.insert("print-float".into(), Type::Func(vec![Type::F64], Box::new(Type::Unit)));
        TypeChecker {
            env: vec![globals],
            func_ret: None,
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
        // First pass: collect all declarations
        for decl in &prog.decls {
            match decl {
                Decl::Def { name, ty, value } => {
                    let inferred = if let Some(ty) = ty {
                        let val_ty = self.check_expr(value)?;
                        if !self.types_equal(ty, &val_ty) {
                            return Err(TypeError {
                                msg: format!(
                                    "type mismatch in definition of '{}': expected {}, got {}",
                                    name, ty, val_ty
                                ),
                            });
                        }
                        ty.clone()
                    } else {
                        self.check_expr(value)?
                    };
                    self.bind(name.clone(), inferred);
                }
                Decl::DefFn { name, params, ret, body } => {
                    let func_ty = Type::Func(
                        params.iter().map(|(_, t)| t.clone()).collect(),
                        Box::new(ret.clone()),
                    );
                    self.bind(name.clone(), func_ty);
                }
                Decl::Extern { name, ty } => {
                    self.bind(name.clone(), ty.clone());
                }
            }
        }

        // Second pass: check function bodies
        for decl in &prog.decls {
            if let Decl::DefFn { name, params, ret, body } = decl {
                self.push_scope();
                for (param, ty) in params {
                    self.bind(param.clone(), ty.clone());
                }
                let old_ret = self.func_ret.clone();
                self.func_ret = Some(ret.clone());
                let body_ty = self.check_expr(body)?;
                self.func_ret = old_ret;
                self.pop_scope();

                if !self.types_equal(ret, &body_ty) {
                    return Err(TypeError {
                        msg: format!(
                            "function '{}' return type mismatch: expected {}, got {}",
                            name, ret, body_ty
                        ),
                    });
                }
            }
        }

        Ok(())
    }

    fn check_expr(&mut self, expr: &Expr) -> Result<Type, TypeError> {
        match expr {
            Expr::Literal(lit) => match lit {
                Literal::Int(_) => Ok(Type::I64), // Default to i64
                Literal::Float(_) => Ok(Type::F64),
                Literal::Bool(_) => Ok(Type::Bool),
                Literal::Char(_) => Ok(Type::Char),
                Literal::String(_) => Ok(Type::Var("String".into())), // Not fully supported yet
                Literal::Unit => Ok(Type::Unit),
            },
            Expr::Var(name) => {
                self.lookup(name).ok_or_else(|| TypeError {
                    msg: format!("unbound variable: {}", name),
                })
            }
            Expr::Binary { op, lhs, rhs } => {
                let lhs_ty = self.check_expr(lhs)?;
                let rhs_ty = self.check_expr(rhs)?;

                match op {
                    BinOp::Add | BinOp::Sub | BinOp::Mul | BinOp::Div | BinOp::Mod => {
                        if !lhs_ty.is_numeric() || !rhs_ty.is_numeric() {
                            return Err(TypeError {
                                msg: format!(
                                    "arithmetic operator requires numeric types, got {} and {}",
                                    lhs_ty, rhs_ty
                                ),
                            });
                        }
                        if !self.types_equal(&lhs_ty, &rhs_ty) {
                            return Err(TypeError {
                                msg: format!(
                                    "type mismatch in arithmetic: {} and {}",
                                    lhs_ty, rhs_ty
                                ),
                            });
                        }
                        Ok(lhs_ty)
                    }
                    BinOp::Eq | BinOp::Ne | BinOp::Lt | BinOp::Le | BinOp::Gt | BinOp::Ge => {
                        if !self.types_equal(&lhs_ty, &rhs_ty) {
                            return Err(TypeError {
                                msg: format!(
                                    "comparison type mismatch: {} and {}",
                                    lhs_ty, rhs_ty
                                ),
                            });
                        }
                        Ok(Type::Bool)
                    }
                    BinOp::And | BinOp::Or => {
                        if lhs_ty != Type::Bool || rhs_ty != Type::Bool {
                            return Err(TypeError {
                                msg: format!(
                                    "logical operator requires bool, got {} and {}",
                                    lhs_ty, rhs_ty
                                ),
                            });
                        }
                        Ok(Type::Bool)
                    }
                    BinOp::BitAnd | BinOp::BitOr | BinOp::BitXor | BinOp::Shl | BinOp::Shr => {
                        if !lhs_ty.is_integer() || !rhs_ty.is_integer() {
                            return Err(TypeError {
                                msg: format!(
                                    "bitwise operator requires integer types, got {} and {}",
                                    lhs_ty, rhs_ty
                                ),
                            });
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
                            return Err(TypeError {
                                msg: format!("negation requires numeric type, got {}", ty),
                            });
                        }
                        Ok(ty)
                    }
                    UnOp::Not => {
                        if ty != Type::Bool {
                            return Err(TypeError {
                                msg: format!("not requires bool, got {}", ty),
                            });
                        }
                        Ok(Type::Bool)
                    }
                    UnOp::BitNot => {
                        if !ty.is_integer() {
                            return Err(TypeError {
                                msg: format!("bit-not requires integer, got {}", ty),
                            });
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
                            return Err(TypeError {
                                msg: format!(
                                    "function expects {} arguments, got {}",
                                    param_tys.len(),
                                    args.len()
                                ),
                            });
                        }
                        for (expected, arg) in param_tys.iter().zip(args.iter()) {
                            let arg_ty = self.check_expr(arg)?;
                            if !self.types_equal(expected, &arg_ty) {
                                return Err(TypeError {
                                    msg: format!(
                                        "argument type mismatch: expected {}, got {}",
                                        expected, arg_ty
                                    ),
                                });
                            }
                        }
                        Ok(*ret_ty)
                    }
                    _ => Err(TypeError {
                        msg: format!("expected function type, got {}", func_ty),
                    }),
                }
            }
            Expr::If { cond, then_branch, else_branch } => {
                let cond_ty = self.check_expr(cond)?;
                if cond_ty != Type::Bool {
                    return Err(TypeError {
                        msg: format!("if condition must be bool, got {}", cond_ty),
                    });
                }
                let then_ty = self.check_expr(then_branch)?;
                let else_ty = self.check_expr(else_branch)?;
                if !self.types_equal(&then_ty, &else_ty) {
                    return Err(TypeError {
                        msg: format!(
                            "if branches have different types: {} and {}",
                            then_ty, else_ty
                        ),
                    });
                }
                Ok(then_ty)
            }
            Expr::Let { bindings, body } => {
                self.push_scope();
                for (name, ty, value) in bindings {
                    let val_ty = self.check_expr(value)?;
                    let binding_ty = if let Some(expected) = ty {
                        if !self.types_equal(expected, &val_ty) {
                            return Err(TypeError {
                                msg: format!(
                                    "let binding '{}' type mismatch: expected {}, got {}",
                                    name, expected, val_ty
                                ),
                            });
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
                    return Err(TypeError {
                        msg: format!(
                            "lambda return type mismatch: expected {}, got {}",
                            ret_ty, body_ty
                        ),
                    });
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
                            return Err(TypeError {
                                msg: format!(
                                    "tuple index {} out of bounds (len {})",
                                    index,
                                    elems.len()
                                ),
                            });
                        }
                        Ok(elems[*index].clone())
                    }
                    _ => Err(TypeError {
                        msg: format!("tuple-ref requires tuple type, got {}", ty),
                    }),
                }
            }
            Expr::Array(elems) => {
                if elems.is_empty() {
                    return Err(TypeError {
                        msg: "cannot infer type of empty array".into(),
                    });
                }
                let first_ty = self.check_expr(&elems[0])?;
                for e in &elems[1..] {
                    let ty = self.check_expr(e)?;
                    if !self.types_equal(&first_ty, &ty) {
                        return Err(TypeError {
                            msg: "array elements must have same type".into(),
                        });
                    }
                }
                Ok(Type::Array(Box::new(first_ty), elems.len()))
            }
            Expr::ArrayRef { expr, index } => {
                let arr_ty = self.check_expr(expr)?;
                let idx_ty = self.check_expr(index)?;
                if !idx_ty.is_integer() {
                    return Err(TypeError {
                        msg: format!("array index must be integer, got {}", idx_ty),
                    });
                }
                match arr_ty {
                    Type::Array(elem_ty, _) => Ok(*elem_ty),
                    _ => Err(TypeError {
                        msg: format!("array-ref requires array type, got {}", arr_ty),
                    }),
                }
            }
            Expr::While { cond, body } => {
                let cond_ty = self.check_expr(cond)?;
                if cond_ty != Type::Bool {
                    return Err(TypeError {
                        msg: format!("while condition must be bool, got {}", cond_ty),
                    });
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
                let var_ty = self.lookup(name).ok_or_else(|| TypeError {
                    msg: format!("unbound variable in set!: {}", name),
                })?;
                if !self.types_equal(&var_ty, &val_ty) {
                    return Err(TypeError {
                        msg: format!(
                            "set! type mismatch: variable {} has type {}, got {}",
                            name, var_ty, val_ty
                        ),
                    });
                }
                Ok(Type::Unit)
            }
            Expr::Ann { expr, ty } => {
                let expr_ty = self.check_expr(expr)?;
                if !self.types_equal(ty, &expr_ty) {
                    return Err(TypeError {
                        msg: format!(
                            "type annotation mismatch: expected {}, got {}",
                            ty, expr_ty
                        ),
                    });
                }
                Ok(ty.clone())
            }
        }
    }

    fn types_equal(&self, a: &Type, b: &Type) -> bool {
        match (a, b) {
            (Type::Var(_), _) | (_, Type::Var(_)) => true, // Type variables unify with anything
            (Type::Func(a_args, a_ret), Type::Func(b_args, b_ret)) => {
                a_args.len() == b_args.len()
                    && a_args.iter().zip(b_args.iter()).all(|(a, b)| self.types_equal(a, b))
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
        let prog = parse(r#"
            (define (add [a : i64] [b : i64]) : i64 (+ a b))
        "#).unwrap();
        let mut tc = TypeChecker::new();
        assert!(tc.check_program(&prog).is_ok());
    }

    #[test]
    fn test_typecheck_error() {
        let prog = parse(r#"
            (define (bad [a : i64] [b : bool]) : i64 (+ a b))
        "#).unwrap();
        let mut tc = TypeChecker::new();
        assert!(tc.check_program(&prog).is_err());
    }
}
