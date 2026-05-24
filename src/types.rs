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
    /// Compile-time-only region tag for heap-backed handles created within a
    /// `(with-region name ...)` scope. Lowering strips this wrapper before IR.
    Region(String, Box<Type>),
    /// Immutable string. As a *value* a string is a pointer to its inline fat
    /// `{ ptr, len }` representation (16 bytes: data pointer + i64 length), so —
    /// like an enum — it is pointer-sized everywhere it flows through the IR.
    /// The underlying bytes live in `.rodata` for string literals.
    String,
    /// Unit / void
    Unit,
    /// Internal bottom type for expressions that never produce a value.
    /// This is not user-denotable syntax; the typechecker uses it for builtin
    /// `panic` / `error` and coerces it at expected-type sites.
    Never,
    /// Function type: (-> arg1 arg2 ... ret). Function values are pointer-sized
    /// closure descriptor pointers; direct named calls keep the normal function
    /// ABI.
    Func(Vec<Type>, Box<Type>),
    /// Tuple type: (Tuple t1 t2 ...). As a *value* a tuple is a pointer to
    /// inline element storage. The storage itself lays out fields sequentially
    /// with natural alignment, but the value flowing through IR is pointer-sized.
    Tuple(Vec<Type>),
    /// Fixed-size array: (Array type size)
    Array(Box<Type>, usize),
    /// Dynamic (runtime-sized) array: `(Array type)`. As a *value* it is a
    /// pointer to its inline fat `{ ptr, len }` representation (16 bytes: a
    /// `tl_alloc`'d element buffer pointer + an i64 element count), so — like an
    /// enum or string — it is pointer-sized everywhere it flows through the IR.
    DynArray(Box<Type>),
    /// Nominal sum type (tagged union) declared with `(defenum Name ...)`.
    /// Carries only the enum's name; the variant layout lives in the
    /// typechecker/lowerer's `EnumRegistry`. As a *value* an enum is always a
    /// pointer to its inline `{ tag, payload }` storage, so it is pointer-sized
    /// everywhere it flows through the IR.
    Enum(String),
    /// Nominal record type declared with `(defstruct Name (field Ty) ...)`.
    /// Carries only the struct's name; the field layout (names, types, byte
    /// offsets, total size) lives in the typechecker/lowerer's `StructRegistry`.
    /// As a *value* a struct is always a pointer to its inline field storage, so
    /// it is pointer-sized everywhere it flows through the IR — exactly like an
    /// enum, but with no tag (a struct is a single, untagged record).
    Struct(String),
    /// Internal SIMD vector type used by backend-oriented IR. This is not a
    /// public source type in the initial SPMD surface.
    #[allow(dead_code)]
    Vector(Box<Type>, usize),
    /// Internal SIMD lane mask type used by backend-oriented IR. This is not a
    /// public source type in the initial SPMD surface.
    #[allow(dead_code)]
    Mask(usize),
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
            Type::Region(region, inner) => write!(f, "(in {} {})", region, inner),
            Type::String => write!(f, "String"),
            Type::Unit => write!(f, "unit"),
            Type::Never => write!(f, "never"),
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
            Type::DynArray(ty) => write!(f, "(Array {})", ty),
            Type::Enum(name) => write!(f, "{}", name),
            Type::Struct(name) => write!(f, "{}", name),
            Type::Vector(elem, lanes) => write!(f, "(Vector {} {})", elem, lanes),
            Type::Mask(lanes) => write!(f, "(Mask {})", lanes),
            Type::Var(name) => write!(f, "'{}'", name),
        }
    }
}

impl Type {
    /// Size in bytes for x86_64
    #[allow(dead_code)]
    pub fn size(&self) -> usize {
        match self {
            Type::I64 | Type::U64 | Type::F64 => 8,
            Type::I32 | Type::U32 | Type::F32 => 4,
            Type::I16 | Type::U16 => 2,
            Type::I8 | Type::U8 | Type::Bool | Type::Char => 1,
            Type::Region(_, inner) => inner.size(),
            Type::Unit => 0,
            Type::Func(_, _) => 8, // closure descriptor pointer
            // A tuple *value* is a pointer to its inline element storage.
            Type::Tuple(_) => 8,
            Type::Array(ty, n) => ty.size() * n,
            // A dynamic-array *value* is a pointer to its inline `{ ptr, len }`
            // storage.
            Type::DynArray(_) => 8,
            // An enum *value* is a pointer to its inline tagged storage.
            Type::Enum(_) => 8,
            // A struct *value* is a pointer to its inline field storage.
            Type::Struct(_) => 8,
            // A string *value* is a pointer to its inline `{ ptr, len }` storage.
            Type::String => 8,
            Type::Vector(elem, lanes) => elem.size() * lanes,
            Type::Mask(lanes) => *lanes,
            Type::Never => panic!("cannot compute size of never type"),
            Type::Var(_) => panic!("cannot compute size of type variable"),
        }
    }

    /// Alignment in bytes
    #[allow(dead_code)]
    pub fn align(&self) -> usize {
        match self {
            Type::I64 | Type::U64 | Type::F64 => 8,
            Type::I32 | Type::U32 | Type::F32 => 4,
            Type::I16 | Type::U16 => 2,
            Type::I8 | Type::U8 | Type::Bool | Type::Char | Type::Unit => 1,
            Type::Region(_, inner) => inner.align(),
            Type::Func(_, _) => 8,
            Type::Tuple(_) => 8,
            Type::Array(ty, _) => ty.align(),
            Type::DynArray(_) => 8,
            Type::Enum(_) => 8,
            Type::Struct(_) => 8,
            Type::String => 8,
            Type::Vector(elem, _) => elem.align(),
            Type::Mask(_) => 1,
            Type::Never => panic!("cannot compute alignment of never type"),
            Type::Var(_) => panic!("cannot compute alignment of type variable"),
        }
    }

    pub fn is_numeric(&self) -> bool {
        if let Type::Region(_, inner) = self {
            return inner.is_numeric();
        }
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
        if let Type::Region(_, inner) = self {
            return inner.is_integer();
        }
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
        )
    }

    #[allow(dead_code)]
    pub fn is_signed(&self) -> bool {
        if let Type::Region(_, inner) = self {
            return inner.is_signed();
        }
        matches!(self, Type::I64 | Type::I32 | Type::I16 | Type::I8)
    }

    #[allow(dead_code)]
    /// Bit width for integer types. Panics on non-integer.
    pub fn bit_width(&self) -> u8 {
        match self {
            Type::Region(_, inner) => inner.bit_width(),
            Type::I64 | Type::U64 => 64,
            Type::I32 | Type::U32 => 32,
            Type::I16 | Type::U16 => 16,
            Type::I8 | Type::U8 => 8,
            _ => panic!("bit_width only defined for integer types"),
        }
    }

    #[allow(dead_code)]
    pub fn is_float(&self) -> bool {
        if let Type::Region(_, inner) = self {
            return inner.is_float();
        }
        matches!(self, Type::F64 | Type::F32)
    }

    #[allow(dead_code)]
    pub fn is_vector(&self) -> bool {
        if let Type::Region(_, inner) = self {
            return inner.is_vector();
        }
        matches!(self, Type::Vector(_, _))
    }

    #[allow(dead_code)]
    pub fn is_mask(&self) -> bool {
        if let Type::Region(_, inner) = self {
            return inner.is_mask();
        }
        matches!(self, Type::Mask(_))
    }

    pub fn strip_regions(&self) -> Type {
        match self {
            Type::Region(_, inner) => inner.strip_regions(),
            Type::Func(args, ret) => Type::Func(
                args.iter().map(Type::strip_regions).collect(),
                Box::new(ret.strip_regions()),
            ),
            Type::Tuple(elems) => Type::Tuple(elems.iter().map(Type::strip_regions).collect()),
            Type::Array(elem, n) => Type::Array(Box::new(elem.strip_regions()), *n),
            Type::DynArray(elem) => Type::DynArray(Box::new(elem.strip_regions())),
            Type::Vector(elem, lanes) => Type::Vector(Box::new(elem.strip_regions()), *lanes),
            other => other.clone(),
        }
    }
}

/// Layout of the inline fat-string representation a `Type::String` value points
/// at: a data pointer at offset 0 followed by an i64 byte length at offset 8.
/// Total 16 bytes, 8-byte aligned.
pub const STRING_FAT_SIZE: usize = 16;
/// Byte offset of the data pointer within the fat-string storage.
pub const STRING_PTR_OFFSET: usize = 0;
/// Byte offset of the length field within the fat-string storage.
pub const STRING_LEN_OFFSET: usize = 8;

/// Size in bytes of a dynamic array's inline fat `{ ptr, len }` value.
pub const DYN_ARRAY_FAT_SIZE: usize = 16;
/// Byte offset of the element-buffer pointer within the fat array value.
pub const DYN_ARRAY_PTR_OFFSET: usize = 0;
/// Byte offset of the i64 element count within the fat array value.
pub const DYN_ARRAY_LEN_OFFSET: usize = 8;
