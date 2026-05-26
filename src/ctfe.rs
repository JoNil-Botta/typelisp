//! Compile-Time Function Evaluation (CTFE) evaluator for expression-position
//! `(comptime expr)`.
//!
//! The first slices support scalar runtime-representable values
//! (i64, f64, bool, char, unit) plus compile-time-only type values. Strings,
//! arrays, tuples, structs, enums, lambdas, calls, and all side-effecting forms
//! are rejected.

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
    Type(Type),
}

impl CtfeValue {
    pub fn runtime_ty(&self) -> Option<Type> {
        match self {
            CtfeValue::I64(_) => Some(Type::I64),
            CtfeValue::F64(_) => Some(Type::F64),
            CtfeValue::Bool(_) => Some(Type::Bool),
            CtfeValue::Char(_) => Some(Type::Char),
            CtfeValue::Unit => Some(Type::Unit),
            CtfeValue::Type(_) => None,
        }
    }

    pub fn type_label(&self) -> String {
        match self.runtime_ty() {
            Some(ty) => ty.to_string(),
            None => "type".into(),
        }
    }

    pub fn key_fragment(&self) -> String {
        match self {
            CtfeValue::I64(n) => format!("i64:{n}"),
            CtfeValue::F64(n) => format!("f64:{:016x}", n.to_bits()),
            CtfeValue::Bool(b) => {
                if *b {
                    "bool:1".into()
                } else {
                    "bool:0".into()
                }
            }
            CtfeValue::Char(c) => format!("char:{:x}", *c as u32),
            CtfeValue::Unit => "unit".into(),
            CtfeValue::Type(ty) => format!("type:{}", ty),
        }
    }

    pub fn to_literal(&self) -> Option<Literal> {
        match self {
            CtfeValue::I64(n) => Some(Literal::Int(*n)),
            CtfeValue::F64(n) => Some(Literal::Float(*n)),
            CtfeValue::Bool(b) => Some(Literal::Bool(*b)),
            CtfeValue::Char(c) => Some(Literal::Char(*c)),
            CtfeValue::Unit => Some(Literal::Unit),
            CtfeValue::Type(_) => None,
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
        Expr::TypeLiteral { .. } => "type literal",
        Expr::If { .. } => "if",
        Expr::Let { .. } => "let",
        Expr::Lambda { .. } => "lambda",
        Expr::Tuple(_) => "tuple",
        Expr::TupleRef { .. } => "tuple-ref",
        Expr::Array(_) => "array",
        Expr::MakeArray { .. } => "make-array",
        Expr::ArrayRef { .. } => "array-ref",
        Expr::ArraySet { .. } => "array-set!",
        Expr::While { .. } => "while",
        Expr::Begin(_) => "begin",
        Expr::Set(_, _) => "set!",
        Expr::Ann { .. } => "type annotation",
        Expr::Cast { .. } => "cast",
        Expr::Match { .. } => "match",
        Expr::Foreach { .. } => "foreach",
        Expr::SpmdReduce { .. } => "spmd-reduce",
        Expr::StructGet { .. } => "struct-get",
        Expr::WithRegion { .. } => "with-arena",
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

    /// Evaluate a CTFE expression.
    pub fn eval(&mut self, expr: &Expr) -> Result<CtfeValue, CtfeError> {
        self.eval_with_type_resolver(expr, |ty, _span| Ok(ty.clone()))
    }

    pub fn eval_with_type_resolver<F>(
        &mut self,
        expr: &Expr,
        resolve_type: F,
    ) -> Result<CtfeValue, CtfeError>
    where
        F: Fn(&Type, Span) -> Result<Type, CtfeError>,
    {
        self.eval_expr(expr, &resolve_type)
    }

    fn eval_expr<F>(&mut self, expr: &Expr, resolve_type: &F) -> Result<CtfeValue, CtfeError>
    where
        F: Fn(&Type, Span) -> Result<Type, CtfeError>,
    {
        let span = expr.span();
        self.use_fuel(span)?;

        match expr.unspan() {
            Expr::Literal(lit) => self.eval_literal(lit, span),
            Expr::Var(name) => self.eval_var(name, span),
            Expr::Binary { op, lhs, rhs } => self.eval_binary(*op, lhs, rhs, span, resolve_type),
            Expr::Unary { op, expr } => self.eval_unary(*op, expr, span, resolve_type),
            Expr::If {
                cond,
                then_branch,
                else_branch,
            } => self.eval_if(cond, then_branch, else_branch, span, resolve_type),
            Expr::Let { bindings, body } => self.eval_let(bindings, body, span, resolve_type),
            Expr::Begin(exprs) => self.eval_begin(exprs, span, resolve_type),
            Expr::Ann { expr, .. } => self.eval_expr(expr, resolve_type),
            Expr::Comptime { expr } => self.eval_expr(expr, resolve_type),
            Expr::TypeLiteral { ty } => Ok(CtfeValue::Type(resolve_type(ty, span)?)),
            Expr::Spanned { expr, .. } => self.eval_expr(expr, resolve_type),
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

    fn eval_binary<F>(
        &mut self,
        op: BinOp,
        lhs: &Expr,
        rhs: &Expr,
        span: Span,
        resolve_type: &F,
    ) -> Result<CtfeValue, CtfeError>
    where
        F: Fn(&Type, Span) -> Result<Type, CtfeError>,
    {
        let lv = self.eval_expr(lhs, resolve_type)?;
        let rv = self.eval_expr(rhs, resolve_type)?;

        // Helper for mismatched-type errors.
        let bad_types = |hint: &str| {
            Err(CtfeError::Message {
                msg: format!(
                    "'{}' in comptime: {} (got {} and {})",
                    op_name(op),
                    hint,
                    lv.type_label(),
                    rv.type_label()
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
                (CtfeValue::Type(a), CtfeValue::Type(b)) => CtfeValue::Bool(a == b),
                _ => return bad_types("requires matching types"),
            },
            BinOp::Ne => match (&lv, &rv) {
                (CtfeValue::I64(a), CtfeValue::I64(b)) => CtfeValue::Bool(a != b),
                (CtfeValue::F64(a), CtfeValue::F64(b)) => CtfeValue::Bool(a != b),
                (CtfeValue::Bool(a), CtfeValue::Bool(b)) => CtfeValue::Bool(a != b),
                (CtfeValue::Char(a), CtfeValue::Char(b)) => CtfeValue::Bool(a != b),
                (CtfeValue::Unit, CtfeValue::Unit) => CtfeValue::Bool(false),
                (CtfeValue::Type(a), CtfeValue::Type(b)) => CtfeValue::Bool(a != b),
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

    fn eval_unary<F>(
        &mut self,
        op: UnOp,
        expr: &Expr,
        span: Span,
        resolve_type: &F,
    ) -> Result<CtfeValue, CtfeError>
    where
        F: Fn(&Type, Span) -> Result<Type, CtfeError>,
    {
        let v = self.eval_expr(expr, resolve_type)?;
        match op {
            UnOp::Neg => match v {
                CtfeValue::I64(n) => Ok(CtfeValue::I64(n.wrapping_neg())),
                CtfeValue::F64(n) => Ok(CtfeValue::F64(-n)),
                other => Err(CtfeError::Message {
                    msg: format!(
                        "negation in comptime requires a numeric type, got {}",
                        other.type_label()
                    ),
                    span,
                }),
            },
            UnOp::Not => match v {
                CtfeValue::Bool(b) => Ok(CtfeValue::Bool(!b)),
                other => Err(CtfeError::Message {
                    msg: format!(
                        "'not' in comptime requires bool, got {}",
                        other.type_label()
                    ),
                    span,
                }),
            },
            UnOp::BitNot => match v {
                CtfeValue::I64(n) => Ok(CtfeValue::I64(!n)),
                other => Err(CtfeError::Message {
                    msg: format!(
                        "bitwise not in comptime requires i64, got {}",
                        other.type_label()
                    ),
                    span,
                }),
            },
        }
    }

    fn eval_if<F>(
        &mut self,
        cond: &Expr,
        then_branch: &Expr,
        else_branch: &Expr,
        _span: Span,
        resolve_type: &F,
    ) -> Result<CtfeValue, CtfeError>
    where
        F: Fn(&Type, Span) -> Result<Type, CtfeError>,
    {
        let cond_val = self.eval_expr(cond, resolve_type)?;
        match cond_val {
            CtfeValue::Bool(true) => self.eval_expr(then_branch, resolve_type),
            CtfeValue::Bool(false) => self.eval_expr(else_branch, resolve_type),
            other => Err(CtfeError::Message {
                msg: format!(
                    "comptime 'if' condition must be bool, got {}",
                    other.type_label()
                ),
                span: cond.span(),
            }),
        }
    }

    fn eval_let<F>(
        &mut self,
        bindings: &[(String, Option<Type>, Expr)],
        body: &Expr,
        _span: Span,
        resolve_type: &F,
    ) -> Result<CtfeValue, CtfeError>
    where
        F: Fn(&Type, Span) -> Result<Type, CtfeError>,
    {
        self.push_scope();
        for (name, _ty, value_expr) in bindings {
            let val = self.eval_expr(value_expr, resolve_type)?;
            self.bind(name.clone(), val);
        }
        let result = self.eval_expr(body, resolve_type);
        self.pop_scope();
        result
    }

    fn eval_begin<F>(
        &mut self,
        exprs: &[Expr],
        _span: Span,
        resolve_type: &F,
    ) -> Result<CtfeValue, CtfeError>
    where
        F: Fn(&Type, Span) -> Result<Type, CtfeError>,
    {
        let mut last = CtfeValue::Unit;
        for e in exprs {
            last = self.eval_expr(e, resolve_type)?;
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::parser::{ReplItem, parse_repl_item};

    fn repl_expr(source: &str) -> Expr {
        match parse_repl_item(source).unwrap() {
            ReplItem::Expr(expr) => expr,
            other => panic!("expected expression, got {:?}", other),
        }
    }

    #[test]
    fn type_literal_evaluates_to_ctfe_type_value() {
        let expr = repl_expr("(type (Array i64 4))");
        let value = CtfeEvaluator::new().eval(&expr).unwrap();

        assert_eq!(value, CtfeValue::Type(Type::Array(Box::new(Type::I64), 4)));
        assert_eq!(value.runtime_ty(), None);
        assert_eq!(value.type_label(), "type");
        assert_eq!(value.key_fragment(), "type:(Array i64 4)");
    }

    #[test]
    fn type_values_compare_in_ctfe() {
        let same = repl_expr("(= (type i64) (type i64))");
        let different = repl_expr("(= (type i64) (type i32))");

        assert_eq!(
            CtfeEvaluator::new().eval(&same).unwrap(),
            CtfeValue::Bool(true)
        );
        assert_eq!(
            CtfeEvaluator::new().eval(&different).unwrap(),
            CtfeValue::Bool(false)
        );
    }
}
