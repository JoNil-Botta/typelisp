use crate::span::Span;
use crate::types::Type;
use std::collections::HashMap;

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
#[allow(dead_code)]
pub enum UnOp {
    Neg,
    Not,
    BitNot,
}

/// Pattern for destructuring bindings
#[derive(Debug, Clone, PartialEq)]
pub enum Pattern {
    #[allow(dead_code)]
    Var(Symbol, Option<Type>),
    #[allow(dead_code)]
    Tuple(Vec<Pattern>),
    /// Irrefutable wildcard: `_`.
    Wildcard,
    /// Variant pattern: `(Variant binding...)` or a nullary `Variant`.
    /// The bindings name the variant's payload fields positionally.
    Variant { name: Symbol, bindings: Vec<Symbol> },
    /// Literal pattern: matches a scalar scrutinee against a constant, e.g.
    /// `0`, `true`, `#\a`. Refutable; used when matching on a scalar
    /// (non-enum) value rather than an enum.
    Literal(Literal),
}

/// A variant of a `defenum`: a constructor name and its (ordered) payload
/// field types. A nullary variant has an empty `fields` list.
#[derive(Debug, Clone, PartialEq)]
pub struct VariantDef {
    pub name: Symbol,
    pub fields: Vec<Type>,
}

/// A named, typed field of a `defstruct`. Fields are ordered; their byte
/// offsets and the struct's total size are computed by the `StructRegistry`.
#[derive(Debug, Clone, PartialEq)]
pub struct FieldDef {
    pub name: Symbol,
    pub ty: Type,
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
    Extern { name: Symbol, ty: Type },
    /// (defenum Name (Variant Ty...) (Variant2 ...) ...)
    DefEnum {
        name: Symbol,
        variants: Vec<VariantDef>,
    },
    /// (defstruct Name (field1 Ty1) (field2 Ty2) ...)
    DefStruct { name: Symbol, fields: Vec<FieldDef> },
    /// (import "path") — a directive consumed by the module-graph loader, not a
    /// codegen declaration. The string is the import path as written, resolved
    /// relative to the importing file by the loader. Import decls are stripped
    /// from the concatenated `Program` before typecheck/lower/codegen, so the
    /// downstream stages never act on them.
    Import(String),
}

/// Expressions
#[derive(Debug, Clone, PartialEq)]
pub enum Expr {
    /// Expression paired with its source span.
    Spanned { expr: Box<Expr>, span: Span },
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
    #[allow(dead_code)]
    Unary { op: UnOp, expr: Box<Expr> },
    /// Function application: (f arg1 arg2 ...)
    Call { func: Box<Expr>, args: Vec<Expr> },
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
    TupleRef { expr: Box<Expr>, index: usize },
    /// Array construction: (array e1 e2 ...)
    Array(Vec<Expr>),
    /// Dynamic-array construction: `(make-array elem-ty len)`. Allocates a
    /// runtime-sized buffer of `len` elements of type `elem-ty` via `tl_alloc`
    /// and yields a fat `{ ptr, len }` array value.
    MakeArray { elem_ty: Type, len: Box<Expr> },
    /// Array access: (array-ref expr index)
    ArrayRef { expr: Box<Expr>, index: Box<Expr> },
    /// In-place array mutation: `(array-set! expr index value)`. Stores `value`
    /// into element `index` of dynamic array `expr` (bounds-checked at runtime),
    /// mutating the existing heap buffer in place. Evaluates to Unit.
    ArraySet {
        expr: Box<Expr>,
        index: Box<Expr>,
        value: Box<Expr>,
    },
    /// String byte indexing: `(string-ref s i)` / `(char-at s i)`. Returns the
    /// byte at index `i` of String `s` as a `char`, bounds-checked at runtime.
    StringRef { expr: Box<Expr>, index: Box<Expr> },
    /// While loop: (while cond body)
    While { cond: Box<Expr>, body: Box<Expr> },
    /// Begin / sequence: (begin e1 e2 ...)
    Begin(Vec<Expr>),
    /// Set! for mutable variables: (set! name expr)
    Set(Symbol, Box<Expr>),
    /// Type annotation: (ann expr : type)
    Ann { expr: Box<Expr>, ty: Type },
    /// Width/representation cast: (cast expr : type). Unlike `ann` (which only
    /// asserts a type), `cast` converts the value to `ty`, truncating or
    /// sign/zero-extending integers as needed.
    Cast { expr: Box<Expr>, ty: Type },
    /// Pattern match: (match scrutinee [pattern body] ...)
    Match {
        scrutinee: Box<Expr>,
        arms: Vec<(Pattern, Expr)>,
    },
    /// Struct field access: `(struct-get s field)`. Reads the named field of the
    /// struct value `s`.
    StructGet { expr: Box<Expr>, field: Symbol },
}

/// A complete program
#[derive(Debug, Clone, PartialEq)]
pub struct Program {
    pub decls: Vec<Decl>,
}

impl Expr {
    pub fn spanned(expr: Expr, span: Span) -> Self {
        Expr::Spanned {
            expr: Box::new(expr),
            span,
        }
    }

    pub fn span(&self) -> Span {
        match self {
            Expr::Spanned { span, .. } => *span,
            _ => Span::default(),
        }
    }

    pub fn unspan(&self) -> &Expr {
        match self {
            Expr::Spanned { expr, .. } => expr.unspan(),
            _ => self,
        }
    }

    #[allow(dead_code)]
    pub fn unit() -> Self {
        Expr::Literal(Literal::Unit)
    }

    #[allow(dead_code)]
    pub fn int(n: i64) -> Self {
        Expr::Literal(Literal::Int(n))
    }

    #[allow(dead_code)]
    pub fn bool(b: bool) -> Self {
        Expr::Literal(Literal::Bool(b))
    }
}

/// The size in bytes of an enum's tag, stored at offset 0 of every value.
pub const ENUM_TAG_SIZE: usize = 8;

/// A registry of all `defenum` declarations in a program, used by both the
/// typechecker (for constructor/variant typing) and the lowerer (for memory
/// layout). Built once from the program's `Decl::DefEnum`s.
#[derive(Debug, Clone, Default)]
pub struct EnumRegistry {
    /// enum name -> its ordered variants.
    enums: HashMap<Symbol, Vec<VariantDef>>,
    /// variant name -> (owning enum name, tag index). Variant names are assumed
    /// globally unique across enums (a later enhancement could qualify them).
    variants: HashMap<Symbol, (Symbol, usize)>,
}

impl EnumRegistry {
    /// Build the registry from a program's `defenum` declarations.
    pub fn from_program(prog: &Program) -> Self {
        let mut reg = EnumRegistry::default();
        for decl in &prog.decls {
            if let Decl::DefEnum { name, variants } = decl {
                for (tag, v) in variants.iter().enumerate() {
                    reg.variants.insert(v.name.clone(), (name.clone(), tag));
                }
                reg.enums.insert(name.clone(), variants.clone());
            }
        }
        reg
    }

    pub fn is_enum(&self, name: &str) -> bool {
        self.enums.contains_key(name)
    }

    pub fn variants(&self, enum_name: &str) -> Option<&[VariantDef]> {
        self.enums.get(enum_name).map(|v| v.as_slice())
    }

    /// Look up a variant by name, returning its owning enum, tag and field types.
    pub fn lookup_variant(&self, variant: &str) -> Option<(&str, usize, &[Type])> {
        let (enum_name, tag) = self.variants.get(variant)?;
        let fields = &self.enums.get(enum_name)?[*tag].fields;
        Some((enum_name.as_str(), *tag, fields.as_slice()))
    }

    /// The payload field types of an enum's `tag`-th variant.
    pub fn lookup_variant_fields(&self, enum_name: &str, tag: usize) -> &[Type] {
        self.enums
            .get(enum_name)
            .and_then(|vs| vs.get(tag))
            .map(|v| v.fields.as_slice())
            .unwrap_or(&[])
    }

    /// Resolve a parsed type so that any `Type::Var(name)` naming a declared
    /// enum becomes `Type::Enum(name)`. Recurses through compound types so enum
    /// names nested in tuples/arrays/function types are resolved too.
    pub fn resolve_type(&self, ty: &Type) -> Type {
        match ty {
            Type::Var(name) if self.is_enum(name) => Type::Enum(name.clone()),
            Type::Func(args, ret) => Type::Func(
                args.iter().map(|a| self.resolve_type(a)).collect(),
                Box::new(self.resolve_type(ret)),
            ),
            Type::Tuple(elems) => Type::Tuple(elems.iter().map(|e| self.resolve_type(e)).collect()),
            Type::Array(elem, n) => Type::Array(Box::new(self.resolve_type(elem)), *n),
            Type::DynArray(elem) => Type::DynArray(Box::new(self.resolve_type(elem))),
            other => other.clone(),
        }
    }

    /// Byte offsets of a variant's payload fields, the first starting just after
    /// the tag. Each field is naturally aligned to its own alignment.
    pub fn field_offsets(&self, fields: &[Type]) -> Vec<usize> {
        let mut offsets = Vec::with_capacity(fields.len());
        let mut cursor = ENUM_TAG_SIZE;
        for f in fields {
            let align = f.align().max(1);
            cursor = cursor.div_ceil(align) * align;
            offsets.push(cursor);
            cursor += f.size();
        }
        offsets
    }

    /// The total inline storage size of an enum value: tag plus the largest
    /// variant payload, rounded up to 8-byte alignment.
    pub fn enum_size(&self, enum_name: &str) -> usize {
        let Some(variants) = self.enums.get(enum_name) else {
            return ENUM_TAG_SIZE;
        };
        let mut max_extent = ENUM_TAG_SIZE;
        for v in variants {
            let offsets = self.field_offsets(&v.fields);
            if let Some(&last) = offsets.last() {
                let extent = last + v.fields.last().map(|f| f.size()).unwrap_or(0);
                max_extent = max_extent.max(extent);
            }
        }
        max_extent.div_ceil(8) * 8
    }
}

/// A registry of all `defstruct` declarations in a program, used by both the
/// typechecker (for constructor/field-access typing) and the lowerer (for
/// memory layout). Built once from the program's `Decl::DefStruct`s. A struct
/// is like an enum with a single, untagged "variant": named fields laid out
/// inline, each naturally aligned, with no tag word.
#[derive(Debug, Clone, Default)]
pub struct StructRegistry {
    /// struct name -> its ordered fields.
    structs: HashMap<Symbol, Vec<FieldDef>>,
}

impl StructRegistry {
    /// Build the registry from a program's `defstruct` declarations.
    pub fn from_program(prog: &Program) -> Self {
        let mut reg = StructRegistry::default();
        for decl in &prog.decls {
            if let Decl::DefStruct { name, fields } = decl {
                reg.structs.insert(name.clone(), fields.clone());
            }
        }
        reg
    }

    pub fn is_struct(&self, name: &str) -> bool {
        self.structs.contains_key(name)
    }

    /// The ordered fields of a struct, if declared.
    pub fn fields(&self, struct_name: &str) -> Option<&[FieldDef]> {
        self.structs.get(struct_name).map(|f| f.as_slice())
    }

    /// Look up a field by name within a struct, returning its declared index
    /// (position in the field list) and its type. `None` if the struct has no
    /// such field.
    pub fn lookup_field(&self, struct_name: &str, field: &str) -> Option<(usize, &Type)> {
        let fields = self.structs.get(struct_name)?;
        fields
            .iter()
            .enumerate()
            .find(|(_, f)| f.name == field)
            .map(|(i, f)| (i, &f.ty))
    }

    /// Resolve a parsed type so any `Type::Var(name)` naming a declared struct
    /// becomes `Type::Struct(name)`. Recurses through compound types so struct
    /// names nested in tuples/arrays/function types are resolved too. Mirrors
    /// `EnumRegistry::resolve_type`; the two run in sequence at the call sites.
    pub fn resolve_type(&self, ty: &Type) -> Type {
        match ty {
            Type::Var(name) if self.is_struct(name) => Type::Struct(name.clone()),
            Type::Func(args, ret) => Type::Func(
                args.iter().map(|a| self.resolve_type(a)).collect(),
                Box::new(self.resolve_type(ret)),
            ),
            Type::Tuple(elems) => Type::Tuple(elems.iter().map(|e| self.resolve_type(e)).collect()),
            Type::Array(elem, n) => Type::Array(Box::new(self.resolve_type(elem)), *n),
            Type::DynArray(elem) => Type::DynArray(Box::new(self.resolve_type(elem))),
            other => other.clone(),
        }
    }

    /// Byte offsets of a struct's fields, each naturally aligned to its own
    /// alignment, starting at offset 0 (a struct has no tag word).
    pub fn field_offsets(&self, fields: &[FieldDef]) -> Vec<usize> {
        let field_tys: Vec<Type> = fields.iter().map(|f| self.resolve_type(&f.ty)).collect();
        Self::field_offsets_for_types(&field_tys)
    }

    /// Byte offsets for an already-resolved ordered field type list.
    pub fn field_offsets_for_types(fields: &[Type]) -> Vec<usize> {
        let mut offsets = Vec::with_capacity(fields.len());
        let mut cursor = 0usize;
        for ty in fields {
            let align = ty.align().max(1);
            cursor = cursor.div_ceil(align) * align;
            offsets.push(cursor);
            cursor += ty.size();
        }
        offsets
    }

    /// The total inline storage size of a struct value: the end of the last
    /// field, rounded up to 8-byte alignment. An empty struct is 8 bytes (one
    /// pointer-sized slot) so it remains a valid, distinct heap/frame address.
    #[cfg(test)]
    pub fn struct_size(&self, struct_name: &str) -> usize {
        let Some(fields) = self.structs.get(struct_name) else {
            return 8;
        };
        let field_tys: Vec<Type> = fields.iter().map(|f| self.resolve_type(&f.ty)).collect();
        Self::struct_size_for_types(&field_tys)
    }

    /// Total inline storage size for an already-resolved ordered field type list.
    pub fn struct_size_for_types(fields: &[Type]) -> usize {
        let offsets = Self::field_offsets_for_types(fields);
        let extent = offsets
            .last()
            .map(|&last| last + fields.last().map(Type::size).unwrap_or(0))
            .unwrap_or(0);
        extent.div_ceil(8).max(1) * 8
    }
}
