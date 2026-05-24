//! Compile-Time Function Evaluation (CTFE) evaluator for expression-position
//! `(comptime expr)`.
//!
//! The first slice supports only scalar runtime-representable values:
//! i64, f64, bool, char, unit.  Strings, arrays, tuples, structs, enums,
//! lambdas, calls, and all side-effecting forms are rejected.

use crate::ast::{BinOp, Expr, Literal, UnOp};
use crate::span::Span;
use crate::types::Type;
use std::collections::HashMap;

#[derive(Debug, Clone)]
pub enum CtfeError {
    Message { msg: String, span: Span },
}

/// A compile-time value in the first scalar slice.
#[derive(Debug, Clone, PartialEq)]
pub enum CtfeValue {
    I64(i64),
    F64(f64),
    Bool(bool),
    Char(char),
    Unit,
}

impl CtfeValue {
    pub fn ty(&self) -> Type {
        match self {
            CtfeValue::I64(_) => Type::I64,
            CtfeValue::F64(_) => Type::F64,
            CtfeValue::Bool(_) => Type::Bool,
            CtfeValue::Char(_) => Type::Char,
            CtfeValue::Unit => Type::Unit,
        }
    }
}

fn describe_expr(expr: &Expr) -> &'static str {
    match expr {
        Expr::Spanned { .. } => "expression",
        Expr::Literal(_) => "literal",
        Expr::Var(_) => "variable reference",
        Expr::Binary { .. } => "binary operation",
        Expr::Unary { .. } => "unary operation",
        Expr::Call { .. } => "function call",
        Expr::Comptime { .. } => "comptime",
        Expr::If { .. } => "if",
        Expr::Let { .. } => "let",
        Expr::Lambda { .. } => "lambda",
        Expr::Tuple(_) => "tuple",
        Expr::TupleRef { .. } => "tuple-ref",
        Expr::Array(_) => "array",
        Expr::MakeArray { .. } => "make-array",
        Expr::ArrayRef { .. } => "array-ref",
        Expr::ArraySet { .. } => "array-set!",
        Expr::StringRef { .. } => "string-ref",
        Expr::While { .. } => "while",
        Expr::Begin(_) => "begin",
        Expr::Set(_, _) => "set!",
        Expr::Ann { .. } => "type annotation",
        Expr::Cast { .. } => "cast",
        Expr::Match { .. } => "match",
        Expr::Foreach { .. } => "foreach",
        Expr::SpmdReduce { .. } => "spmd-reduce",
        Expr::StructGet { .. } => "struct-get",
    }
}

/// Evaluates a single `(comptime expr)` body.
pub struct CtfeEvaluator {
    scopes: Vec<HashMap<String, CtfeValue>>,
    fuel: u64,
}

impl Default for CtfeEvaluator {
    fn default() -> Self {
        Self::new()
    }
}

impl CtfeEvaluator {
    pub fn new() -> Self {
        Self {
            scopes: vec![HashMap::new()],
            fuel: 10_000,
        }
    }

    fn push_scope(&mut self) {
        self.scopes.push(HashMap::new());
    }

    fn pop_scope(&mut self) {
        self.scopes.pop();
    }

    fn bind(&mut self, name: String, value: CtfeValue) {
        if let Some(scope) = self.scopes.last_mut() {
            scope.insert(name, value);
        }
    }

    fn lookup(&self, name: &str) -> Option<CtfeValue> {
        for scope in self.scopes.iter().rev() {
            if let Some(v) = scope.get(name) {
                return Some(v.clone());
            }
        }
        None
    }

    fn use_fuel(&mut self, span: Span) -> Result<(), CtfeError> {
        if self.fuel == 0 {
            return Err(CtfeError::Message {
                msg: "compile-time evaluation limit exceeded".into(),
                span,
            });
        }
        self.fuel -= 1;
        Ok(())
    }

    /// Evaluate a CTFE expression, returning the scalar value.
    pub fn eval(&mut self, expr: &Expr) -> Result<CtfeValue, CtfeError> {
        self.eval_expr(expr)
    }

    fn eval_expr(&mut self, expr: &Expr) -> Result<CtfeValue, CtfeError> {
        let span = expr.span();
        self.use_fuel(span)?;

        match expr.unspan() {
            Expr::Literal(lit) => self.eval_literal(lit, span),
            Expr::Var(name) => self.eval_var(name, span),
            Expr::Binary { op, lhs, rhs } => self.eval_binary(*op, lhs, rhs, span),
            Expr::Unary { op, expr } => self.eval_unary(*op, expr, span),
            Expr::If {
                cond,
                then_branch,
                else_branch,
            } => self.eval_if(cond, then_branch, else_branch, span),
            Expr::Let { bindings, body } => self.eval_let(bindings, body, span),
            Expr::Begin(exprs) => self.eval_begin(exprs, span),
            Expr::Ann { expr, .. } => self.eval_expr(expr),
            Expr::Comptime { expr } => self.eval_expr(expr),
            Expr::Spanned { expr, .. } => self.eval_expr(expr),
            other => Err(CtfeError::Message {
                msg: format!(
                    "'{}' is not supported in compile-time evaluation",
                    describe_expr(other)
                ),
                span,
            }),
        }
    }

    fn eval_literal(&self, lit: &Literal, span: Span) -> Result<CtfeValue, CtfeError> {
        match lit {
            Literal::Int(n) => Ok(CtfeValue::I64(*n)),
            Literal::Float(n) => Ok(CtfeValue::F64(*n)),
            Literal::Bool(b) => Ok(CtfeValue::Bool(*b)),
            Literal::Char(c) => Ok(CtfeValue::Char(*c)),
            Literal::Unit => Ok(CtfeValue::Unit),
            Literal::String(_) => Err(CtfeError::Message {
                msg: "strings are not supported in compile-time evaluation".into(),
                span,
            }),
        }
    }

    fn eval_var(&self, name: &str, span: Span) -> Result<CtfeValue, CtfeError> {
        self.lookup(name).ok_or_else(|| CtfeError::Message {
            msg: format!(
                "compile-time evaluation cannot reference runtime variable '{}'",
                name
            ),
            span,
        })
    }

    fn eval_binary(
        &mut self,
        op: BinOp,
        lhs: &Expr,
        rhs: &Expr,
        span: Span,
    ) -> Result<CtfeValue, CtfeError> {
        let lv = self.eval_expr(lhs)?;
        let rv = self.eval_expr(rhs)?;

        // Helper for mismatched-type errors.
        let bad_types = |hint: &str| {
            Err(CtfeError::Message {
                msg: format!(
                    "'{}' in comptime: {} (got {} and {})",
                    op_name(op),
                    hint,
                    lv.ty(),
                    rv.ty()
                ),
                span,
            })
        };

        let res = match op {
            // Arithmetic.
            BinOp::Add => match (&lv, &rv) {
                (CtfeValue::I64(a), CtfeValue::I64(b)) => CtfeValue::I64(a.wrapping_add(*b)),
                (CtfeValue::F64(a), CtfeValue::F64(b)) => CtfeValue::F64(a + b),
                _ => return bad_types("requires matching numeric types"),
            },
            BinOp::Sub => match (&lv, &rv) {
                (CtfeValue::I64(a), CtfeValue::I64(b)) => CtfeValue::I64(a.wrapping_sub(*b)),
                (CtfeValue::F64(a), CtfeValue::F64(b)) => CtfeValue::F64(a - b),
                _ => return bad_types("requires matching numeric types"),
            },
            BinOp::Mul => match (&lv, &rv) {
                (CtfeValue::I64(a), CtfeValue::I64(b)) => CtfeValue::I64(a.wrapping_mul(*b)),
                (CtfeValue::F64(a), CtfeValue::F64(b)) => CtfeValue::F64(a * b),
                _ => return bad_types("requires matching numeric types"),
            },
            BinOp::Div => match (&lv, &rv) {
                (CtfeValue::I64(a), CtfeValue::I64(b)) => {
                    if *b == 0 {
                        return Err(CtfeError::Message {
                            msg: "division by zero in comptime".into(),
                            span,
                        });
                    }
                    CtfeValue::I64(a.wrapping_div(*b))
                }
                (CtfeValue::F64(a), CtfeValue::F64(b)) => CtfeValue::F64(a / b),
                _ => return bad_types("requires matching numeric types"),
            },
            BinOp::Mod => match (&lv, &rv) {
                (CtfeValue::I64(a), CtfeValue::I64(b)) => {
                    if *b == 0 {
                        return Err(CtfeError::Message {
                            msg: "modulo by zero in comptime".into(),
                            span,
                        });
                    }
                    CtfeValue::I64(a.wrapping_rem(*b))
                }
                (CtfeValue::F64(a), CtfeValue::F64(b)) => CtfeValue::F64(a % b),
                _ => return bad_types("requires matching numeric types"),
            },

            // Comparison.
            BinOp::Eq => match (&lv, &rv) {
                (CtfeValue::I64(a), CtfeValue::I64(b)) => CtfeValue::Bool(a == b),
                (CtfeValue::F64(a), CtfeValue::F64(b)) => CtfeValue::Bool(a == b),
                (CtfeValue::Bool(a), CtfeValue::Bool(b)) => CtfeValue::Bool(a == b),
                (CtfeValue::Char(a), CtfeValue::Char(b)) => CtfeValue::Bool(a == b),
                (CtfeValue::Unit, CtfeValue::Unit) => CtfeValue::Bool(true),
                _ => return bad_types("requires matching types"),
            },
            BinOp::Ne => match (&lv, &rv) {
                (CtfeValue::I64(a), CtfeValue::I64(b)) => CtfeValue::Bool(a != b),
                (CtfeValue::F64(a), CtfeValue::F64(b)) => CtfeValue::Bool(a != b),
                (CtfeValue::Bool(a), CtfeValue::Bool(b)) => CtfeValue::Bool(a != b),
                (CtfeValue::Char(a), CtfeValue::Char(b)) => CtfeValue::Bool(a != b),
                (CtfeValue::Unit, CtfeValue::Unit) => CtfeValue::Bool(false),
                _ => return bad_types("requires matching types"),
            },
            BinOp::Lt => match (&lv, &rv) {
                (CtfeValue::I64(a), CtfeValue::I64(b)) => CtfeValue::Bool(a < b),
                (CtfeValue::F64(a), CtfeValue::F64(b)) => CtfeValue::Bool(a < b),
                (CtfeValue::Char(a), CtfeValue::Char(b)) => CtfeValue::Bool(a < b),
                _ => return bad_types("requires ordered matching types"),
            },
            BinOp::Le => match (&lv, &rv) {
                (CtfeValue::I64(a), CtfeValue::I64(b)) => CtfeValue::Bool(a <= b),
                (CtfeValue::F64(a), CtfeValue::F64(b)) => CtfeValue::Bool(a <= b),
                (CtfeValue::Char(a), CtfeValue::Char(b)) => CtfeValue::Bool(a <= b),
                _ => return bad_types("requires ordered matching types"),
            },
            BinOp::Gt => match (&lv, &rv) {
                (CtfeValue::I64(a), CtfeValue::I64(b)) => CtfeValue::Bool(a > b),
                (CtfeValue::F64(a), CtfeValue::F64(b)) => CtfeValue::Bool(a > b),
                (CtfeValue::Char(a), CtfeValue::Char(b)) => CtfeValue::Bool(a > b),
                _ => return bad_types("requires ordered matching types"),
            },
            BinOp::Ge => match (&lv, &rv) {
                (CtfeValue::I64(a), CtfeValue::I64(b)) => CtfeValue::Bool(a >= b),
                (CtfeValue::F64(a), CtfeValue::F64(b)) => CtfeValue::Bool(a >= b),
                (CtfeValue::Char(a), CtfeValue::Char(b)) => CtfeValue::Bool(a >= b),
                _ => return bad_types("requires ordered matching types"),
            },

            // Boolean.
            BinOp::And => match (&lv, &rv) {
                (CtfeValue::Bool(a), CtfeValue::Bool(b)) => CtfeValue::Bool(*a && *b),
                _ => return bad_types("requires bool operands"),
            },
            BinOp::Or => match (&lv, &rv) {
                (CtfeValue::Bool(a), CtfeValue::Bool(b)) => CtfeValue::Bool(*a || *b),
                _ => return bad_types("requires bool operands"),
            },

            // Bitwise.
            BinOp::BitAnd => match (&lv, &rv) {
                (CtfeValue::I64(a), CtfeValue::I64(b)) => CtfeValue::I64(a & b),
                _ => return bad_types("requires integer operands"),
            },
            BinOp::BitOr => match (&lv, &rv) {
                (CtfeValue::I64(a), CtfeValue::I64(b)) => CtfeValue::I64(a | b),
                _ => return bad_types("requires integer operands"),
            },
            BinOp::BitXor => match (&lv, &rv) {
                (CtfeValue::I64(a), CtfeValue::I64(b)) => CtfeValue::I64(a ^ b),
                _ => return bad_types("requires integer operands"),
            },
            BinOp::Shl => match (&lv, &rv) {
                (CtfeValue::I64(a), CtfeValue::I64(b)) => CtfeValue::I64(a.wrapping_shl(*b as u32)),
                _ => return bad_types("requires integer operands"),
            },
            BinOp::Shr => match (&lv, &rv) {
                (CtfeValue::I64(a), CtfeValue::I64(b)) => CtfeValue::I64(a.wrapping_shr(*b as u32)),
                _ => return bad_types("requires integer operands"),
            },
        };

        Ok(res)
    }

    fn eval_unary(&mut self, op: UnOp, expr: &Expr, span: Span) -> Result<CtfeValue, CtfeError> {
        let v = self.eval_expr(expr)?;
        match op {
            UnOp::Neg => match v {
                CtfeValue::I64(n) => Ok(CtfeValue::I64(n.wrapping_neg())),
                CtfeValue::F64(n) => Ok(CtfeValue::F64(-n)),
                other => Err(CtfeError::Message {
                    msg: format!(
                        "negation in comptime requires a numeric type, got {}",
                        other.ty()
                    ),
                    span,
                }),
            },
            UnOp::Not => match v {
                CtfeValue::Bool(b) => Ok(CtfeValue::Bool(!b)),
                other => Err(CtfeError::Message {
                    msg: format!("'not' in comptime requires bool, got {}", other.ty()),
                    span,
                }),
            },
            UnOp::BitNot => match v {
                CtfeValue::I64(n) => Ok(CtfeValue::I64(!n)),
                other => Err(CtfeError::Message {
                    msg: format!("bitwise not in comptime requires i64, got {}", other.ty()),
                    span,
                }),
            },
        }
    }

    fn eval_if(
        &mut self,
        cond: &Expr,
        then_branch: &Expr,
        else_branch: &Expr,
        _span: Span,
    ) -> Result<CtfeValue, CtfeError> {
        let cond_val = self.eval_expr(cond)?;
        match cond_val {
            CtfeValue::Bool(true) => self.eval_expr(then_branch),
            CtfeValue::Bool(false) => self.eval_expr(else_branch),
            other => Err(CtfeError::Message {
                msg: format!("comptime 'if' condition must be bool, got {}", other.ty()),
                span: cond.span(),
            }),
        }
    }

    fn eval_let(
        &mut self,
        bindings: &[(String, Option<Type>, Expr)],
        body: &Expr,
        _span: Span,
    ) -> Result<CtfeValue, CtfeError> {
        self.push_scope();
        for (name, _ty, value_expr) in bindings {
            let val = self.eval_expr(value_expr)?;
            self.bind(name.clone(), val);
        }
        let result = self.eval_expr(body);
        self.pop_scope();
        result
    }

    fn eval_begin(&mut self, exprs: &[Expr], _span: Span) -> Result<CtfeValue, CtfeError> {
        let mut last = CtfeValue::Unit;
        for e in exprs {
            last = self.eval_expr(e)?;
        }
        Ok(last)
    }
}

fn op_name(op: BinOp) -> &'static str {
    match op {
        BinOp::Add => "+",
        BinOp::Sub => "-",
        BinOp::Mul => "*",
        BinOp::Div => "/",
        BinOp::Mod => "%",
        BinOp::Eq => "==",
        BinOp::Ne => "!=",
        BinOp::Lt => "<",
        BinOp::Le => "<=",
        BinOp::Gt => ">",
        BinOp::Ge => ">=",
        BinOp::And => "and",
        BinOp::Or => "or",
        BinOp::BitAnd => "bitand",
        BinOp::BitOr => "bitor",
        BinOp::BitXor => "bitxor",
        BinOp::Shl => "shl",
        BinOp::Shr => "shr",
    }
}
