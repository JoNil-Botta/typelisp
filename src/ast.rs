use crate::types::Type;

/// Unique identifier for variables, functions, etc.
pub type Symbol = String;

/// Literal values
#[derive(Debug, Clone, PartialEq)]
pub enum Literal {
    Int(i64),
    Float(f64),
    Bool(bool),
    Char(char),
    String(String),
    Unit,
}

/// Binary operators
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BinOp {
    Add,
    Sub,
    Mul,
    Div,
    Mod,
    Eq,
    Ne,
    Lt,
    Le,
    Gt,
    Ge,
    And,
    Or,
    BitAnd,
    BitOr,
    BitXor,
    Shl,
    Shr,
}

/// Unary operators
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UnOp {
    Neg,
    Not,
    BitNot,
}

/// Pattern for destructuring bindings
#[derive(Debug, Clone, PartialEq)]
pub enum Pattern {
    Var(Symbol, Option<Type>),
    Tuple(Vec<Pattern>),
    Wildcard,
}

/// Top-level declarations
#[derive(Debug, Clone, PartialEq)]
pub enum Decl {
    /// (define name [: type] expr)
    Def {
        name: Symbol,
        ty: Option<Type>,
        value: Expr,
    },
    /// (define (name [arg : type] ...) [: ret-type] body)
    DefFn {
        name: Symbol,
        params: Vec<(Symbol, Type)>,
        ret: Type,
        body: Expr,
    },
    /// (extern name [: (-> ... ret)])
    Extern {
        name: Symbol,
        ty: Type,
    },
}

/// Expressions
#[derive(Debug, Clone, PartialEq)]
pub enum Expr {
    /// Literal value
    Literal(Literal),
    /// Variable reference
    Var(Symbol),
    /// Binary operation: (+ lhs rhs)
    Binary {
        op: BinOp,
        lhs: Box<Expr>,
        rhs: Box<Expr>,
    },
    /// Unary operation: (- expr)
    Unary {
        op: UnOp,
        expr: Box<Expr>,
    },
    /// Function application: (f arg1 arg2 ...)
    Call {
        func: Box<Expr>,
        args: Vec<Expr>,
    },
    /// If expression: (if cond then else)
    If {
        cond: Box<Expr>,
        then_branch: Box<Expr>,
        else_branch: Box<Expr>,
    },
    /// Let binding: (let ([name : type value] ...) body)
    Let {
        bindings: Vec<(Symbol, Option<Type>, Expr)>,
        body: Box<Expr>,
    },
    /// Lambda: (lambda ([arg : type] ...) [: ret] body)
    Lambda {
        params: Vec<(Symbol, Type)>,
        ret: Option<Type>,
        body: Box<Expr>,
    },
    /// Tuple construction: (tuple e1 e2 ...)
    Tuple(Vec<Expr>),
    /// Tuple access: (tuple-ref expr index)
    TupleRef {
        expr: Box<Expr>,
        index: usize,
    },
    /// Array construction: (array e1 e2 ...)
    Array(Vec<Expr>),
    /// Array access: (array-ref expr index)
    ArrayRef {
        expr: Box<Expr>,
        index: Box<Expr>,
    },
    /// While loop: (while cond body)
    While {
        cond: Box<Expr>,
        body: Box<Expr>,
    },
    /// Begin / sequence: (begin e1 e2 ...)
    Begin(Vec<Expr>),
    /// Set! for mutable variables: (set! name expr)
    Set(Symbol, Box<Expr>),
    /// Type annotation: (ann expr : type)
    Ann {
        expr: Box<Expr>,
        ty: Type,
    },
}

/// A complete program
#[derive(Debug, Clone, PartialEq)]
pub struct Program {
    pub decls: Vec<Decl>,
}

impl Expr {
    pub fn unit() -> Self {
        Expr::Literal(Literal::Unit)
    }

    pub fn int(n: i64) -> Self {
        Expr::Literal(Literal::Int(n))
    }

    pub fn bool(b: bool) -> Self {
        Expr::Literal(Literal::Bool(b))
    }
}
