use std::fmt;

/// Core types in the TypeLisp type system.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum Type {
    /// Signed integers
    I64,
    I32,
    I16,
    I8,
    /// Unsigned integers
    U64,
    U32,
    U16,
    U8,
    /// Floating point
    F64,
    F32,
    /// Boolean
    Bool,
    /// Character
    Char,
    /// Unit / void
    Unit,
    /// Function type: (-> arg1 arg2 ... ret)
    Func(Vec<Type>, Box<Type>),
    /// Tuple type: (Tuple t1 t2 ...)
    Tuple(Vec<Type>),
    /// Fixed-size array: (Array type size)
    Array(Box<Type>, usize),
    /// Type variable for polymorphism / inference
    Var(String),
}

impl fmt::Display for Type {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Type::I64 => write!(f, "i64"),
            Type::I32 => write!(f, "i32"),
            Type::I16 => write!(f, "i16"),
            Type::I8 => write!(f, "i8"),
            Type::U64 => write!(f, "u64"),
            Type::U32 => write!(f, "u32"),
            Type::U16 => write!(f, "u16"),
            Type::U8 => write!(f, "u8"),
            Type::F64 => write!(f, "f64"),
            Type::F32 => write!(f, "f32"),
            Type::Bool => write!(f, "bool"),
            Type::Char => write!(f, "char"),
            Type::Unit => write!(f, "unit"),
            Type::Func(args, ret) => {
                write!(f, "(->")?;
                for arg in args {
                    write!(f, " {}", arg)?;
                }
                write!(f, " {})", ret)
            }
            Type::Tuple(elems) => {
                write!(f, "(Tuple")?;
                for e in elems {
                    write!(f, " {}", e)?;
                }
                write!(f, ")")
            }
            Type::Array(ty, n) => write!(f, "(Array {} {})", ty, n),
            Type::Var(name) => write!(f, "'{}'", name),
        }
    }
}

impl Type {
    /// Size in bytes for x86_64
    pub fn size(&self) -> usize {
        match self {
            Type::I64 | Type::U64 | Type::F64 => 8,
            Type::I32 | Type::U32 | Type::F32 => 4,
            Type::I16 | Type::U16 => 2,
            Type::I8 | Type::U8 | Type::Bool | Type::Char => 1,
            Type::Unit => 0,
            Type::Func(_, _) => 8, // function pointer
            Type::Tuple(elems) => elems.iter().map(|e| e.size()).sum(),
            Type::Array(ty, n) => ty.size() * n,
            Type::Var(_) => panic!("cannot compute size of type variable"),
        }
    }

    /// Alignment in bytes
    pub fn align(&self) -> usize {
        match self {
            Type::I64 | Type::U64 | Type::F64 => 8,
            Type::I32 | Type::U32 | Type::F32 => 4,
            Type::I16 | Type::U16 => 2,
            Type::I8 | Type::U8 | Type::Bool | Type::Char | Type::Unit => 1,
            Type::Func(_, _) => 8,
            Type::Tuple(elems) => elems.iter().map(|e| e.align()).max().unwrap_or(1),
            Type::Array(ty, _) => ty.align(),
            Type::Var(_) => panic!("cannot compute alignment of type variable"),
        }
    }

    pub fn is_numeric(&self) -> bool {
        matches!(
            self,
            Type::I64
                | Type::I32
                | Type::I16
                | Type::I8
                | Type::U64
                | Type::U32
                | Type::U16
                | Type::U8
                | Type::F64
                | Type::F32
        )
    }

    pub fn is_integer(&self) -> bool {
        matches!(
            self,
            Type::I64 | Type::I32 | Type::I16 | Type::I8 | Type::U64 | Type::U32 | Type::U16 | Type::U8
        )
    }

    pub fn is_signed(&self) -> bool {
        matches!(self, Type::I64 | Type::I32 | Type::I16 | Type::I8)
    }

    pub fn is_float(&self) -> bool {
        matches!(self, Type::F64 | Type::F32)
    }
}
