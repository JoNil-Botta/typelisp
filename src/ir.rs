use crate::span::Span;
use crate::types::Type;
use std::collections::HashMap;
use std::fmt;

/// Intermediate Representation using a simple 3-address code form.
/// This is lowered from the AST and is the input to the optimizer and backend.
pub type VarId = u32;
pub type Label = String;

pub const ABORT_RUNTIME_SYMBOL: &str = ".L_tl_abort";
pub const ARG_COUNT_RUNTIME_SYMBOL: &str = ".L_tl_arg_count";
pub const ARG_RUNTIME_SYMBOL: &str = ".L_tl_arg";
pub const READ_FILE_RUNTIME_SYMBOL: &str = ".L_tl_read_file";
pub const WRITE_FILE_RUNTIME_SYMBOL: &str = ".L_tl_write_file";
pub const FILE_EXISTS_RUNTIME_SYMBOL: &str = ".L_tl_file_exists";
pub const READ_FILE_STATUS_RUNTIME_SYMBOL: &str = ".L_tl_read_file_status";
pub const WRITE_FILE_STATUS_RUNTIME_SYMBOL: &str = ".L_tl_write_file_status";
pub const APPEND_FILE_STATUS_RUNTIME_SYMBOL: &str = ".L_tl_append_file_status";
pub const FILE_EXISTS_STATUS_RUNTIME_SYMBOL: &str = ".L_tl_file_exists_status";
pub const FILE_OPEN_STATUS_RUNTIME_SYMBOL: &str = ".L_tl_file_open_status";
pub const FILE_CLOSE_STATUS_RUNTIME_SYMBOL: &str = ".L_tl_file_close_status";
pub const FILE_READ_CHUNK_STATUS_RUNTIME_SYMBOL: &str = ".L_tl_file_read_chunk_status";
pub const FILE_WRITE_STATUS_RUNTIME_SYMBOL: &str = ".L_tl_file_write_status";
pub const FILE_FLUSH_STATUS_RUNTIME_SYMBOL: &str = ".L_tl_file_flush_status";
pub const FILE_READ_CHUNK_BYTES_RUNTIME_SYMBOL: &str = ".L_tl_file_read_chunk_bytes";
pub const FILE_READ_CHUNK_EOF_RUNTIME_SYMBOL: &str = ".L_tl_file_read_chunk_eof";
pub const READ_STDIN_LINE_RUNTIME_SYMBOL: &str = ".L_tl_read_stdin_line";
pub const READ_STDIN_BYTES_RUNTIME_SYMBOL: &str = ".L_tl_read_stdin_bytes";
pub const STDIN_EOF_RUNTIME_SYMBOL: &str = ".L_tl_stdin_eof";
pub const FLUSH_STDOUT_RUNTIME_SYMBOL: &str = ".L_tl_flush_stdout";
pub const REGION_MARK_RUNTIME_SYMBOL: &str = "tl_region_mark";
pub const REGION_RESET_RUNTIME_SYMBOL: &str = "tl_region_reset";

/// Conservative effect class for an IR instruction. The optimizer uses this
/// to decide what may be dropped or reused without doing alias analysis.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IrEffect {
    /// Computes a value/address only; does not inspect or mutate memory.
    Pure,
    /// Reads memory but does not intentionally mutate it.
    MemoryRead,
    /// Writes memory or allocates storage.
    MemoryWrite,
    /// Changes control flow or may not return.
    ControlFlow,
    /// Calls or host interactions whose effects are not modeled precisely.
    Unknown,
}

impl IrEffect {
    pub fn has_side_effect(self) -> bool {
        matches!(
            self,
            IrEffect::MemoryWrite | IrEffect::ControlFlow | IrEffect::Unknown
        )
    }

    pub fn invalidates_cse(self) -> bool {
        // Without alias analysis, any memory observation/mutation, control
        // boundary, or unknown call is a barrier for available expressions:
        // no load CSE across stores/calls, and no reordering effectful calls.
        !matches!(self, IrEffect::Pure)
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum Value {
    ConstI64(i64),
    ConstI32(i32),
    ConstI8(i8),
    ConstF64(f64),
    ConstBool(bool),
    ConstUnit,
    /// A reference to the raw bytes of a string literal. The backend interns the
    /// bytes into `.rodata` and materializes this operand as the address of
    /// those bytes (the `ptr` field of a fat string). The value is pointer-sized
    /// (a data pointer), used only to populate fat-string storage at lowering.
    ConstStr(String),
    /// Pointer-sized closure descriptor for a named function or extern.
    /// The backend materializes a descriptor address, not a raw code pointer.
    Function(String),
    /// Raw address of a function entry point. Used to build heap closure
    /// descriptors whose environment pointer is only known at runtime.
    FunctionEntry(String),
    Var(VarId),
    Global(String),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
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
    /// Logical and/or (boolean operands).
    And,
    Or,
    /// Bitwise operators on integers.
    BitAnd,
    BitOr,
    BitXor,
    /// Shift left.
    Shl,
    /// Shift right. The signedness of the operand type decides whether the
    /// backend emits an arithmetic (`sar`) or logical (`shr`) shift.
    Shr,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum UnOp {
    Neg,
    /// Logical not (boolean operand): flips 0/1.
    Not,
    /// Bitwise complement (integer operand): one's complement.
    BitNot,
}

#[allow(dead_code)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum MaskBinOp {
    And,
    Or,
}

#[allow(dead_code)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum VectorReduceOp {
    Sum,
    Min,
    Max,
}

#[allow(dead_code)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum MaskReduceOp {
    All,
    Any,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Instruction {
    /// Binary operation: dst = lhs op rhs
    BinOp {
        dst: VarId,
        op: BinOp,
        lhs: Value,
        rhs: Value,
        ty: Type,
    },
    /// Unary operation: dst = op src
    UnOp {
        dst: VarId,
        op: UnOp,
        src: Value,
        ty: Type,
    },
    /// Copy: dst = src
    Mov { dst: VarId, src: Value, ty: Type },
    /// Width/sign conversion: dst = (to_ty) src, where `src` currently has
    /// type `from_ty`. Narrowing truncates; widening sign- or zero-extends
    /// according to `from_ty`'s signedness.
    Cast {
        dst: VarId,
        src: Value,
        from_ty: Type,
        to_ty: Type,
    },
    /// Load from memory: dst = *src
    Load { dst: VarId, src: Value, ty: Type },
    /// Store to memory: *dst = src
    Store { dst: Value, src: Value, ty: Type },
    /// Get address of a variable: dst = &src
    AddrOf { dst: VarId, src: VarId },
    /// Function call: dst = call func(args...)
    Call {
        dst: Option<VarId>,
        func: String,
        args: Vec<Value>,
        ty: Type,
    },
    /// Indirect call through a closure descriptor pointer.
    CallIndirect {
        dst: Option<VarId>,
        func: Value,
        args: Vec<Value>,
        ty: Type,
    },
    /// Direct tail call. The first lowering/codegen slice supports only
    /// self-recursive calls; the backend validates that before emission.
    #[allow(dead_code)]
    TailCall {
        func: String,
        args: Vec<Value>,
        ty: Type,
    },
    /// Conditional branch: if cond goto true_label else false_label
    Branch {
        cond: Value,
        true_label: Label,
        false_label: Label,
    },
    /// Unconditional jump
    Jump(Label),
    /// Return from function
    Return(Option<Value>),
    /// Allocate stack space for a local variable
    Alloc { var: VarId, ty: Type },
    /// Get element pointer: dst = base[offset]
    Gep {
        dst: VarId,
        base: Value,
        offset: Value,
        elem_ty: Type,
    },
    /// Vector lane id: dst = <0, 1, ..., lanes - 1> as a vector of `ty`.
    #[allow(dead_code)]
    LaneId { dst: VarId, lanes: usize, ty: Type },
    /// Splat scalar value across all lanes: dst = <value, ...>.
    #[allow(dead_code)]
    Splat {
        dst: VarId,
        value: Value,
        lanes: usize,
        ty: Type,
    },
    /// Vector binary operation over lane values.
    #[allow(dead_code)]
    VectorBinOp {
        dst: VarId,
        op: BinOp,
        lhs: Value,
        rhs: Value,
        lanes: usize,
        elem_ty: Type,
    },
    /// Horizontal vector reduction. This is a private IR primitive for
    /// `spmd-reduce`; public source-level cross-lane operations remain deferred.
    /// `f64 sum` represents the ordered source-level result and must stay on a
    /// scalar path unless a backend can preserve that contract.
    #[allow(dead_code)]
    VectorReduce {
        dst: VarId,
        op: VectorReduceOp,
        src: Value,
        lanes: usize,
        elem_ty: Type,
    },
    /// Vector comparison, producing a mask.
    #[allow(dead_code)]
    VectorCompare {
        dst: VarId,
        op: BinOp,
        lhs: Value,
        rhs: Value,
        lanes: usize,
        elem_ty: Type,
    },
    /// Binary lane-mask operation.
    #[allow(dead_code)]
    MaskBinOp {
        dst: VarId,
        op: MaskBinOp,
        lhs: Value,
        rhs: Value,
        lanes: usize,
    },
    /// Logical lane-mask complement.
    #[allow(dead_code)]
    MaskNot {
        dst: VarId,
        src: Value,
        lanes: usize,
    },
    /// Horizontal lane-mask reduction to a scalar bool.
    #[allow(dead_code)]
    MaskReduce {
        dst: VarId,
        op: MaskReduceOp,
        src: Value,
        lanes: usize,
    },
    /// Per-lane select: dst = mask ? on_true : on_false.
    #[allow(dead_code)]
    Select {
        dst: VarId,
        mask: Value,
        on_true: Value,
        on_false: Value,
        lanes: usize,
        ty: Type,
    },
    /// Contiguous vector load from base[index + lane].
    #[allow(dead_code)]
    VectorLoad {
        dst: VarId,
        base: Value,
        index: Value,
        lanes: usize,
        elem_ty: Type,
    },
    /// Contiguous vector store to base[index + lane].
    #[allow(dead_code)]
    VectorStore {
        base: Value,
        index: Value,
        value: Value,
        lanes: usize,
        elem_ty: Type,
    },
    /// Contiguous vector store guarded by a lane mask.
    #[allow(dead_code)]
    PredicatedStore {
        base: Value,
        index: Value,
        value: Value,
        mask: Value,
        lanes: usize,
        elem_ty: Type,
    },
    /// Contiguous vector load guarded by a lane mask; inactive lanes read as
    /// zero. Mirrors [`Instruction::PredicatedStore`] with a destination
    /// register so masked tail loads cannot touch unmapped memory.
    #[allow(dead_code)]
    PredicatedLoad {
        dst: VarId,
        base: Value,
        index: Value,
        mask: Value,
        lanes: usize,
        elem_ty: Type,
    },
    /// Tail mask: lane is active when `index + lane < len`.
    #[allow(dead_code)]
    TailMask {
        dst: VarId,
        index: Value,
        len: Value,
        lanes: usize,
    },
    /// Phi node for SSA: dst = phi [(val1, label1), (val2, label2), ...]
    Phi {
        dst: VarId,
        incoming: Vec<(Value, Label)>,
        ty: Type,
    },
}

/// Classify compiler-known direct runtime helper calls. Unknown names remain
/// effectful so ordinary user, extern, and future helper calls default safe.
pub fn classify_direct_call_effect(func: &str) -> IrEffect {
    match func {
        "tl_string_eq" | "tl_string_to_int" | REGION_MARK_RUNTIME_SYMBOL => IrEffect::MemoryRead,
        "tl_alloc"
        | "tl_int_to_string"
        | "tl_substring"
        | "tl_string_concat"
        | REGION_RESET_RUNTIME_SYMBOL => IrEffect::MemoryWrite,
        ABORT_RUNTIME_SYMBOL | "tl_oob_abort" | "tl_div_abort" | "tl_shift_abort" => {
            IrEffect::ControlFlow
        }
        "tl_print_i64"
        | "tl_print_bool"
        | "tl_print_f64"
        | "tl_print_char"
        | "tl_print_newline"
        | "tl_print_str"
        | "tl_print_err"
        | ARG_COUNT_RUNTIME_SYMBOL
        | ARG_RUNTIME_SYMBOL
        | READ_FILE_RUNTIME_SYMBOL
        | WRITE_FILE_RUNTIME_SYMBOL
        | FILE_EXISTS_RUNTIME_SYMBOL
        | READ_FILE_STATUS_RUNTIME_SYMBOL
        | WRITE_FILE_STATUS_RUNTIME_SYMBOL
        | APPEND_FILE_STATUS_RUNTIME_SYMBOL
        | FILE_EXISTS_STATUS_RUNTIME_SYMBOL
        | FILE_OPEN_STATUS_RUNTIME_SYMBOL
        | FILE_CLOSE_STATUS_RUNTIME_SYMBOL
        | FILE_READ_CHUNK_STATUS_RUNTIME_SYMBOL
        | FILE_WRITE_STATUS_RUNTIME_SYMBOL
        | FILE_FLUSH_STATUS_RUNTIME_SYMBOL
        | FILE_READ_CHUNK_BYTES_RUNTIME_SYMBOL
        | FILE_READ_CHUNK_EOF_RUNTIME_SYMBOL
        | READ_STDIN_LINE_RUNTIME_SYMBOL
        | READ_STDIN_BYTES_RUNTIME_SYMBOL => IrEffect::Unknown,
        STDIN_EOF_RUNTIME_SYMBOL => IrEffect::MemoryRead,
        FLUSH_STDOUT_RUNTIME_SYMBOL => IrEffect::MemoryWrite,
        _ => IrEffect::Unknown,
    }
}

impl Instruction {
    pub fn effect(&self) -> IrEffect {
        match self {
            Instruction::BinOp { .. }
            | Instruction::UnOp { .. }
            | Instruction::Mov { .. }
            | Instruction::Cast { .. }
            | Instruction::AddrOf { .. }
            | Instruction::Gep { .. }
            | Instruction::LaneId { .. }
            | Instruction::Splat { .. }
            | Instruction::VectorBinOp { .. }
            | Instruction::VectorReduce { .. }
            | Instruction::VectorCompare { .. }
            | Instruction::MaskBinOp { .. }
            | Instruction::MaskNot { .. }
            | Instruction::MaskReduce { .. }
            | Instruction::Select { .. }
            | Instruction::TailMask { .. }
            | Instruction::Phi { .. } => IrEffect::Pure,
            Instruction::Load { .. }
            | Instruction::VectorLoad { .. }
            | Instruction::PredicatedLoad { .. } => IrEffect::MemoryRead,
            Instruction::Store { .. }
            | Instruction::VectorStore { .. }
            | Instruction::PredicatedStore { .. }
            | Instruction::Alloc { .. } => IrEffect::MemoryWrite,
            Instruction::Call { func, .. } => classify_direct_call_effect(func),
            Instruction::CallIndirect { .. } => IrEffect::Unknown,
            Instruction::TailCall { .. }
            | Instruction::Branch { .. }
            | Instruction::Jump(_)
            | Instruction::Return(_) => IrEffect::ControlFlow,
        }
    }
}

/// A basic block is a sequence of instructions with a single entry point
/// and a single exit point (branch, jump, or return).
#[derive(Debug, Clone, PartialEq)]
pub struct BasicBlock {
    pub label: Label,
    pub instructions: Vec<Instruction>,
}

/// A function in IR form
#[derive(Debug, Clone, PartialEq)]
pub struct Function {
    pub name: String,
    pub params: Vec<(VarId, Type)>,
    pub ret: Type,
    pub locals: Vec<(VarId, Type)>,
    pub blocks: Vec<BasicBlock>,
    pub entry: Label,
}

/// A complete program in IR form
#[derive(Debug, Clone, PartialEq)]
pub struct Program {
    pub functions: Vec<Function>,
    pub globals: Vec<(String, Type, Option<Value>)>,
    pub externs: Vec<(String, Type)>,
}

/// Optional source provenance for lowered IR. Kept outside [`Program`] so the
/// existing optimizer and backend data model remain unchanged; CLI diagnostic
/// paths pass this side table alongside the IR when they want source snippets.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct SourceSpans {
    pub functions: HashMap<String, Span>,
}

/// IR Builder for constructing functions
pub struct IrBuilder {
    current_block: BasicBlock,
    blocks: Vec<BasicBlock>,
    next_var: VarId,
    next_label: u32,
}

impl IrBuilder {
    pub fn new(entry_label: &str) -> Self {
        IrBuilder {
            current_block: BasicBlock {
                label: entry_label.into(),
                instructions: Vec::new(),
            },
            blocks: Vec::new(),
            next_var: 0,
            next_label: 0,
        }
    }

    pub fn fresh_var(&mut self) -> VarId {
        let v = self.next_var;
        self.next_var += 1;
        v
    }

    pub fn fresh_label(&mut self, prefix: &str) -> Label {
        let l = format!("{}.{}", prefix, self.next_label);
        self.next_label += 1;
        l
    }

    pub fn emit(&mut self, instr: Instruction) {
        self.current_block.instructions.push(instr);
    }

    /// The label of the block currently being built.
    pub fn current_label(&self) -> &str {
        &self.current_block.label
    }

    pub fn finish_block(&mut self, next_label: &str) {
        let block = std::mem::replace(
            &mut self.current_block,
            BasicBlock {
                label: next_label.into(),
                instructions: Vec::new(),
            },
        );
        self.blocks.push(block);
    }

    pub fn build(self) -> Vec<BasicBlock> {
        let mut blocks = self.blocks;
        blocks.push(self.current_block);
        blocks
    }
}

impl Value {
    pub fn ty(&self) -> Option<Type> {
        match self {
            Value::ConstI64(_) => Some(Type::I64),
            Value::ConstI32(_) => Some(Type::I32),
            Value::ConstI8(_) => Some(Type::I8),
            Value::ConstF64(_) => Some(Type::F64),
            Value::ConstBool(_) => Some(Type::Bool),
            Value::ConstUnit => Some(Type::Unit),
            // A `ConstStr` operand is the raw data pointer of a string literal,
            // a pointer-sized value.
            Value::ConstStr(_) => Some(Type::U64),
            // The exact function type depends on the symbol table, so callers
            // that need it must use contextual type maps.
            Value::Function(_) | Value::FunctionEntry(_) => None,
            Value::Var(_) | Value::Global(_) => None, // Need type context
        }
    }
}

impl fmt::Display for Value {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Value::ConstI64(n) => write!(f, "{}", n),
            Value::ConstI32(n) => write!(f, "{}", n),
            Value::ConstI8(n) => write!(f, "{}", n),
            Value::ConstF64(n) => write!(f, "{}", n),
            Value::ConstBool(b) => write!(f, "{}", b),
            Value::ConstUnit => write!(f, "unit"),
            Value::ConstStr(s) => write!(f, "{:?}", s),
            Value::Function(name) => write!(f, "&{}", name),
            Value::FunctionEntry(name) => write!(f, "&entry {}", name),
            Value::Var(v) => write!(f, "%{}", v),
            Value::Global(g) => write!(f, "@{}", g),
        }
    }
}

impl fmt::Display for BinOp {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let s = match self {
            BinOp::Add => "add",
            BinOp::Sub => "sub",
            BinOp::Mul => "mul",
            BinOp::Div => "div",
            BinOp::Mod => "mod",
            BinOp::Eq => "eq",
            BinOp::Ne => "ne",
            BinOp::Lt => "lt",
            BinOp::Le => "le",
            BinOp::Gt => "gt",
            BinOp::Ge => "ge",
            BinOp::And => "and",
            BinOp::Or => "or",
            BinOp::BitAnd => "bitand",
            BinOp::BitOr => "bitor",
            BinOp::BitXor => "bitxor",
            BinOp::Shl => "shl",
            BinOp::Shr => "shr",
        };
        write!(f, "{}", s)
    }
}

impl fmt::Display for UnOp {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let s = match self {
            UnOp::Neg => "neg",
            UnOp::Not => "not",
            UnOp::BitNot => "bitnot",
        };
        write!(f, "{}", s)
    }
}

impl fmt::Display for MaskBinOp {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let s = match self {
            MaskBinOp::And => "mask_and",
            MaskBinOp::Or => "mask_or",
        };
        write!(f, "{}", s)
    }
}

impl fmt::Display for VectorReduceOp {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let s = match self {
            VectorReduceOp::Sum => "sum",
            VectorReduceOp::Min => "min",
            VectorReduceOp::Max => "max",
        };
        write!(f, "{}", s)
    }
}

impl fmt::Display for MaskReduceOp {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let s = match self {
            MaskReduceOp::All => "all",
            MaskReduceOp::Any => "any",
        };
        write!(f, "{}", s)
    }
}

impl fmt::Display for Instruction {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Instruction::BinOp {
                dst, op, lhs, rhs, ..
            } => {
                write!(f, "  %{} = {} {}, {}", dst, op, lhs, rhs)
            }
            Instruction::UnOp { dst, op, src, .. } => {
                write!(f, "  %{} = {} {}", dst, op, src)
            }
            Instruction::Mov { dst, src, .. } => {
                write!(f, "  %{} = mov {}", dst, src)
            }
            Instruction::Cast {
                dst,
                src,
                from_ty,
                to_ty,
            } => {
                write!(f, "  %{} = cast {} : {} -> {}", dst, src, from_ty, to_ty)
            }
            Instruction::Load { dst, src, .. } => {
                write!(f, "  %{} = load {}", dst, src)
            }
            Instruction::Store { dst, src, .. } => {
                write!(f, "  store {}, {}", dst, src)
            }
            Instruction::AddrOf { dst, src } => {
                write!(f, "  %{} = addrof %{{{}}}", dst, src)
            }
            Instruction::Call {
                dst, func, args, ..
            } => {
                if let Some(d) = dst {
                    write!(f, "  %{} = call {}", d, func)?;
                } else {
                    write!(f, "  call {}", func)?;
                }
                write!(f, "(")?;
                for (i, arg) in args.iter().enumerate() {
                    if i > 0 {
                        write!(f, ", ")?;
                    }
                    write!(f, "{}", arg)?;
                }
                write!(f, ")")
            }
            Instruction::CallIndirect {
                dst, func, args, ..
            } => {
                if let Some(d) = dst {
                    write!(f, "  %{} = call_indirect {}", d, func)?;
                } else {
                    write!(f, "  call_indirect {}", func)?;
                }
                write!(f, "(")?;
                for (i, arg) in args.iter().enumerate() {
                    if i > 0 {
                        write!(f, ", ")?;
                    }
                    write!(f, "{}", arg)?;
                }
                write!(f, ")")
            }
            Instruction::TailCall { func, args, ty } => {
                write!(f, "  tailcall {}(", func)?;
                for (i, arg) in args.iter().enumerate() {
                    if i > 0 {
                        write!(f, ", ")?;
                    }
                    write!(f, "{}", arg)?;
                }
                write!(f, ") : {}", ty)
            }
            Instruction::Branch {
                cond,
                true_label,
                false_label,
            } => {
                write!(f, "  br {}, {}, {}", cond, true_label, false_label)
            }
            Instruction::Jump(label) => {
                write!(f, "  jmp {}", label)
            }
            Instruction::Return(Some(v)) => {
                write!(f, "  ret {}", v)
            }
            Instruction::Return(None) => {
                write!(f, "  ret")
            }
            Instruction::Alloc { var, ty } => {
                write!(f, "  alloc %{} : {}", var, ty)
            }
            Instruction::Gep {
                dst,
                base,
                offset,
                elem_ty,
            } => {
                write!(f, "  %{} = gep {}, {} : {}", dst, base, offset, elem_ty)
            }
            Instruction::LaneId { dst, lanes, ty } => {
                write!(f, "  %{} = lane_id {} x {}", dst, lanes, ty)
            }
            Instruction::Splat {
                dst,
                value,
                lanes,
                ty,
            } => {
                write!(f, "  %{} = splat {} : {} x {}", dst, value, lanes, ty)
            }
            Instruction::VectorBinOp {
                dst,
                op,
                lhs,
                rhs,
                lanes,
                elem_ty,
            } => {
                write!(
                    f,
                    "  %{} = vector_{} {}, {} : {} x {}",
                    dst, op, lhs, rhs, lanes, elem_ty
                )
            }
            Instruction::VectorReduce {
                dst,
                op,
                src,
                lanes,
                elem_ty,
            } => {
                write!(
                    f,
                    "  %{} = vector_reduce_{} {} : {} x {}",
                    dst, op, src, lanes, elem_ty
                )
            }
            Instruction::VectorCompare {
                dst,
                op,
                lhs,
                rhs,
                lanes,
                elem_ty,
            } => {
                write!(
                    f,
                    "  %{} = vector_cmp_{} {}, {} : {} x {}",
                    dst, op, lhs, rhs, lanes, elem_ty
                )
            }
            Instruction::MaskBinOp {
                dst,
                op,
                lhs,
                rhs,
                lanes,
            } => {
                write!(f, "  %{} = {} {}, {} : {}", dst, op, lhs, rhs, lanes)
            }
            Instruction::MaskNot { dst, src, lanes } => {
                write!(f, "  %{} = mask_not {} : {}", dst, src, lanes)
            }
            Instruction::MaskReduce {
                dst,
                op,
                src,
                lanes,
            } => {
                write!(f, "  %{} = mask_reduce_{} {} : {}", dst, op, src, lanes)
            }
            Instruction::Select {
                dst,
                mask,
                on_true,
                on_false,
                lanes,
                ty,
            } => {
                write!(
                    f,
                    "  %{} = select {}, {}, {} : {} x {}",
                    dst, mask, on_true, on_false, lanes, ty
                )
            }
            Instruction::VectorLoad {
                dst,
                base,
                index,
                lanes,
                elem_ty,
            } => {
                write!(
                    f,
                    "  %{} = vector_load {}, {} : {} x {}",
                    dst, base, index, lanes, elem_ty
                )
            }
            Instruction::VectorStore {
                base,
                index,
                value,
                lanes,
                elem_ty,
            } => {
                write!(
                    f,
                    "  vector_store {}, {}, {} : {} x {}",
                    base, index, value, lanes, elem_ty
                )
            }
            Instruction::PredicatedStore {
                base,
                index,
                value,
                mask,
                lanes,
                elem_ty,
            } => {
                write!(
                    f,
                    "  predicated_store {}, {}, {}, {} : {} x {}",
                    base, index, value, mask, lanes, elem_ty
                )
            }
            Instruction::PredicatedLoad {
                dst,
                base,
                index,
                mask,
                lanes,
                elem_ty,
            } => {
                write!(
                    f,
                    "  %{} = predicated_load {}, {}, {} : {} x {}",
                    dst, base, index, mask, lanes, elem_ty
                )
            }
            Instruction::TailMask {
                dst,
                index,
                len,
                lanes,
            } => {
                write!(f, "  %{} = tail_mask {}, {} : {}", dst, index, len, lanes)
            }
            Instruction::Phi { dst, incoming, ty } => {
                write!(f, "  %{} = phi : {}", dst, ty)?;
                for (val, label) in incoming {
                    write!(f, " [{}, {}]", val, label)?;
                }
                Ok(())
            }
        }
    }
}

impl fmt::Display for BasicBlock {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        writeln!(f, "{}:", self.label)?;
        for instr in &self.instructions {
            writeln!(f, "{}", instr)?;
        }
        Ok(())
    }
}

impl fmt::Display for Function {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "function {}(", self.name)?;
        for (i, (var, ty)) in self.params.iter().enumerate() {
            if i > 0 {
                write!(f, ", ")?;
            }
            write!(f, "%{} : {}", var, ty)?;
        }
        writeln!(f, ") -> {} {{", self.ret)?;
        writeln!(f, "  // locals")?;
        for (var, ty) in &self.locals {
            writeln!(f, "  // %{} : {}", var, ty)?;
        }
        for block in &self.blocks {
            write!(f, "{}", block)?;
        }
        writeln!(f, "}}")
    }
}

impl fmt::Display for Program {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        for (name, ty, val) in &self.globals {
            if let Some(v) = val {
                writeln!(f, "global {} : {} = {}", name, ty, v)?;
            } else {
                writeln!(f, "global {} : {}", name, ty)?;
            }
        }
        for (name, ty) in &self.externs {
            writeln!(f, "extern {} : {}", name, ty)?;
        }
        for func in &self.functions {
            write!(f, "{}", func)?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn i64_ty() -> Type {
        Type::I64
    }

    fn call(func: &str) -> Instruction {
        Instruction::Call {
            dst: Some(0),
            func: func.into(),
            args: vec![Value::ConstI64(1)],
            ty: i64_ty(),
        }
    }

    #[test]
    fn instruction_effect_classifies_every_variant() {
        let pure = IrEffect::Pure;
        assert_eq!(
            Instruction::BinOp {
                dst: 0,
                op: BinOp::Add,
                lhs: Value::ConstI64(1),
                rhs: Value::ConstI64(2),
                ty: i64_ty(),
            }
            .effect(),
            pure
        );
        assert_eq!(
            Instruction::UnOp {
                dst: 0,
                op: UnOp::Neg,
                src: Value::ConstI64(1),
                ty: i64_ty(),
            }
            .effect(),
            pure
        );
        assert_eq!(
            Instruction::Mov {
                dst: 0,
                src: Value::ConstI64(1),
                ty: i64_ty(),
            }
            .effect(),
            pure
        );
        assert_eq!(
            Instruction::Cast {
                dst: 0,
                src: Value::ConstI64(1),
                from_ty: Type::I64,
                to_ty: Type::I32,
            }
            .effect(),
            pure
        );
        assert_eq!(Instruction::AddrOf { dst: 0, src: 1 }.effect(), pure);
        assert_eq!(
            Instruction::Gep {
                dst: 0,
                base: Value::Var(1),
                offset: Value::ConstI64(0),
                elem_ty: i64_ty(),
            }
            .effect(),
            pure
        );
        assert_eq!(
            Instruction::LaneId {
                dst: 0,
                lanes: 4,
                ty: Type::I64,
            }
            .effect(),
            pure
        );
        assert_eq!(
            Instruction::Splat {
                dst: 0,
                value: Value::ConstI64(1),
                lanes: 4,
                ty: Type::I64,
            }
            .effect(),
            pure
        );
        assert_eq!(
            Instruction::VectorBinOp {
                dst: 0,
                op: BinOp::Add,
                lhs: Value::Var(1),
                rhs: Value::Var(2),
                lanes: 4,
                elem_ty: Type::I64,
            }
            .effect(),
            pure
        );
        assert_eq!(
            Instruction::VectorReduce {
                dst: 0,
                op: VectorReduceOp::Sum,
                src: Value::Var(1),
                lanes: 4,
                elem_ty: Type::I64,
            }
            .effect(),
            pure
        );
        assert_eq!(
            Instruction::VectorCompare {
                dst: 0,
                op: BinOp::Lt,
                lhs: Value::Var(1),
                rhs: Value::Var(2),
                lanes: 4,
                elem_ty: Type::I64,
            }
            .effect(),
            pure
        );
        assert_eq!(
            Instruction::MaskBinOp {
                dst: 0,
                op: MaskBinOp::And,
                lhs: Value::Var(1),
                rhs: Value::Var(2),
                lanes: 4,
            }
            .effect(),
            pure
        );
        assert_eq!(
            Instruction::MaskNot {
                dst: 0,
                src: Value::Var(1),
                lanes: 4,
            }
            .effect(),
            pure
        );
        assert_eq!(
            Instruction::MaskReduce {
                dst: 0,
                op: MaskReduceOp::Any,
                src: Value::Var(1),
                lanes: 4,
            }
            .effect(),
            pure
        );
        assert_eq!(
            Instruction::Select {
                dst: 0,
                mask: Value::Var(1),
                on_true: Value::Var(2),
                on_false: Value::Var(3),
                lanes: 4,
                ty: Type::I64,
            }
            .effect(),
            pure
        );
        assert_eq!(
            Instruction::TailMask {
                dst: 0,
                index: Value::Var(1),
                len: Value::Var(2),
                lanes: 4,
            }
            .effect(),
            pure
        );
        assert_eq!(
            Instruction::Phi {
                dst: 0,
                incoming: vec![(Value::ConstI64(1), "entry".into())],
                ty: i64_ty(),
            }
            .effect(),
            pure
        );

        assert_eq!(
            Instruction::Load {
                dst: 0,
                src: Value::Var(1),
                ty: i64_ty(),
            }
            .effect(),
            IrEffect::MemoryRead
        );
        assert_eq!(
            Instruction::VectorLoad {
                dst: 0,
                base: Value::Var(1),
                index: Value::ConstI64(0),
                lanes: 4,
                elem_ty: Type::I64,
            }
            .effect(),
            IrEffect::MemoryRead
        );
        assert_eq!(
            Instruction::Store {
                dst: Value::Var(0),
                src: Value::ConstI64(1),
                ty: i64_ty(),
            }
            .effect(),
            IrEffect::MemoryWrite
        );
        assert_eq!(
            Instruction::Alloc {
                var: 0,
                ty: i64_ty()
            }
            .effect(),
            IrEffect::MemoryWrite
        );
        assert_eq!(
            Instruction::VectorStore {
                base: Value::Var(0),
                index: Value::ConstI64(0),
                value: Value::Var(1),
                lanes: 4,
                elem_ty: Type::I64,
            }
            .effect(),
            IrEffect::MemoryWrite
        );
        assert_eq!(
            Instruction::PredicatedStore {
                base: Value::Var(0),
                index: Value::ConstI64(0),
                value: Value::Var(1),
                mask: Value::Var(2),
                lanes: 4,
                elem_ty: Type::I64,
            }
            .effect(),
            IrEffect::MemoryWrite
        );
        assert_eq!(
            Instruction::PredicatedLoad {
                dst: 0,
                base: Value::Var(1),
                index: Value::ConstI64(0),
                mask: Value::Var(2),
                lanes: 4,
                elem_ty: Type::I64,
            }
            .effect(),
            IrEffect::MemoryRead
        );

        assert_eq!(
            Instruction::CallIndirect {
                dst: Some(0),
                func: Value::Function("f".into()),
                args: vec![],
                ty: i64_ty(),
            }
            .effect(),
            IrEffect::Unknown
        );
        assert_eq!(
            Instruction::TailCall {
                func: "f".into(),
                args: vec![Value::Var(0)],
                ty: i64_ty(),
            }
            .effect(),
            IrEffect::ControlFlow
        );
        assert_eq!(
            Instruction::Branch {
                cond: Value::ConstBool(true),
                true_label: "t".into(),
                false_label: "f".into(),
            }
            .effect(),
            IrEffect::ControlFlow
        );
        assert_eq!(
            Instruction::Jump("next".into()).effect(),
            IrEffect::ControlFlow
        );
        assert_eq!(
            Instruction::Return(Some(Value::ConstI64(0))).effect(),
            IrEffect::ControlFlow
        );
    }

    #[test]
    fn direct_runtime_helper_effects_are_conservative() {
        for func in [
            "tl_string_eq",
            "tl_string_to_int",
            REGION_MARK_RUNTIME_SYMBOL,
            STDIN_EOF_RUNTIME_SYMBOL,
        ] {
            assert_eq!(classify_direct_call_effect(func), IrEffect::MemoryRead);
            assert_eq!(call(func).effect(), IrEffect::MemoryRead);
        }

        for func in [
            "tl_alloc",
            "tl_int_to_string",
            "tl_substring",
            "tl_string_concat",
            REGION_RESET_RUNTIME_SYMBOL,
            FLUSH_STDOUT_RUNTIME_SYMBOL,
        ] {
            assert_eq!(classify_direct_call_effect(func), IrEffect::MemoryWrite);
            assert_eq!(call(func).effect(), IrEffect::MemoryWrite);
        }

        for func in [
            ABORT_RUNTIME_SYMBOL,
            "tl_oob_abort",
            "tl_div_abort",
            "tl_shift_abort",
        ] {
            assert_eq!(classify_direct_call_effect(func), IrEffect::ControlFlow);
            assert_eq!(call(func).effect(), IrEffect::ControlFlow);
        }

        for func in [
            "tl_print_i64",
            "tl_print_bool",
            "tl_print_f64",
            "tl_print_char",
            "tl_print_newline",
            "tl_print_str",
            "tl_print_err",
            ARG_COUNT_RUNTIME_SYMBOL,
            ARG_RUNTIME_SYMBOL,
            READ_FILE_RUNTIME_SYMBOL,
            WRITE_FILE_RUNTIME_SYMBOL,
            FILE_EXISTS_RUNTIME_SYMBOL,
            READ_FILE_STATUS_RUNTIME_SYMBOL,
            WRITE_FILE_STATUS_RUNTIME_SYMBOL,
            APPEND_FILE_STATUS_RUNTIME_SYMBOL,
            FILE_EXISTS_STATUS_RUNTIME_SYMBOL,
            FILE_OPEN_STATUS_RUNTIME_SYMBOL,
            FILE_CLOSE_STATUS_RUNTIME_SYMBOL,
            FILE_READ_CHUNK_STATUS_RUNTIME_SYMBOL,
            FILE_WRITE_STATUS_RUNTIME_SYMBOL,
            FILE_FLUSH_STATUS_RUNTIME_SYMBOL,
            FILE_READ_CHUNK_BYTES_RUNTIME_SYMBOL,
            FILE_READ_CHUNK_EOF_RUNTIME_SYMBOL,
            READ_STDIN_LINE_RUNTIME_SYMBOL,
            READ_STDIN_BYTES_RUNTIME_SYMBOL,
            "user_or_extern_call",
        ] {
            assert_eq!(classify_direct_call_effect(func), IrEffect::Unknown);
            assert_eq!(call(func).effect(), IrEffect::Unknown);
        }
    }

    #[test]
    fn effect_predicates_match_optimizer_conservatism() {
        assert!(!IrEffect::Pure.has_side_effect());
        assert!(!IrEffect::MemoryRead.has_side_effect());
        assert!(IrEffect::MemoryWrite.has_side_effect());
        assert!(IrEffect::ControlFlow.has_side_effect());
        assert!(IrEffect::Unknown.has_side_effect());

        assert!(!IrEffect::Pure.invalidates_cse());
        assert!(IrEffect::MemoryRead.invalidates_cse());
        assert!(IrEffect::MemoryWrite.invalidates_cse());
        assert!(IrEffect::ControlFlow.invalidates_cse());
        assert!(IrEffect::Unknown.invalidates_cse());
    }

    #[test]
    fn vector_and_mask_types_display_as_internal_ir_types() {
        assert_eq!(
            Type::Vector(Box::new(Type::I32), 8).to_string(),
            "(Vector i32 8)"
        );
        assert_eq!(Type::Mask(8).to_string(), "(Mask 8)");
    }

    #[test]
    fn vector_and_mask_reduce_ops_display_supported_set() {
        assert_eq!(VectorReduceOp::Sum.to_string(), "sum");
        assert_eq!(VectorReduceOp::Min.to_string(), "min");
        assert_eq!(VectorReduceOp::Max.to_string(), "max");
        assert_eq!(MaskReduceOp::All.to_string(), "all");
        assert_eq!(MaskReduceOp::Any.to_string(), "any");
    }

    #[test]
    fn vector_and_mask_ir_pretty_prints_each_primitive() {
        let instrs = vec![
            Instruction::LaneId {
                dst: 0,
                lanes: 4,
                ty: Type::I64,
            },
            Instruction::Splat {
                dst: 1,
                value: Value::ConstI64(7),
                lanes: 4,
                ty: Type::I64,
            },
            Instruction::VectorBinOp {
                dst: 2,
                op: BinOp::Add,
                lhs: Value::Var(0),
                rhs: Value::Var(1),
                lanes: 4,
                elem_ty: Type::I64,
            },
            Instruction::VectorReduce {
                dst: 8,
                op: VectorReduceOp::Sum,
                src: Value::Var(2),
                lanes: 4,
                elem_ty: Type::I64,
            },
            Instruction::VectorCompare {
                dst: 3,
                op: BinOp::Lt,
                lhs: Value::Var(0),
                rhs: Value::Var(1),
                lanes: 4,
                elem_ty: Type::I64,
            },
            Instruction::MaskBinOp {
                dst: 4,
                op: MaskBinOp::Or,
                lhs: Value::Var(3),
                rhs: Value::Var(3),
                lanes: 4,
            },
            Instruction::MaskNot {
                dst: 5,
                src: Value::Var(4),
                lanes: 4,
            },
            Instruction::MaskReduce {
                dst: 9,
                op: MaskReduceOp::Any,
                src: Value::Var(5),
                lanes: 4,
            },
            Instruction::Select {
                dst: 6,
                mask: Value::Var(5),
                on_true: Value::Var(2),
                on_false: Value::Var(1),
                lanes: 4,
                ty: Type::I64,
            },
            Instruction::VectorLoad {
                dst: 7,
                base: Value::Var(10),
                index: Value::Var(11),
                lanes: 4,
                elem_ty: Type::I64,
            },
            Instruction::VectorStore {
                base: Value::Var(12),
                index: Value::Var(11),
                value: Value::Var(6),
                lanes: 4,
                elem_ty: Type::I64,
            },
            Instruction::PredicatedStore {
                base: Value::Var(12),
                index: Value::Var(11),
                value: Value::Var(6),
                mask: Value::Var(5),
                lanes: 4,
                elem_ty: Type::I64,
            },
        ];
        let rendered = instrs
            .iter()
            .map(ToString::to_string)
            .collect::<Vec<_>>()
            .join("\n");

        for expected in [
            "%0 = lane_id 4 x i64",
            "%1 = splat 7 : 4 x i64",
            "%2 = vector_add %0, %1 : 4 x i64",
            "%8 = vector_reduce_sum %2 : 4 x i64",
            "%3 = vector_cmp_lt %0, %1 : 4 x i64",
            "%4 = mask_or %3, %3 : 4",
            "%5 = mask_not %4 : 4",
            "%9 = mask_reduce_any %5 : 4",
            "%6 = select %5, %2, %1 : 4 x i64",
            "%7 = vector_load %10, %11 : 4 x i64",
            "vector_store %12, %11, %6 : 4 x i64",
            "predicated_store %12, %11, %6, %5 : 4 x i64",
        ] {
            assert!(
                rendered.contains(expected),
                "missing {expected:?} in:\n{rendered}"
            );
        }
    }

    #[test]
    fn tail_mask_ir_records_index_length_and_lane_width() {
        let instr = Instruction::TailMask {
            dst: 9,
            index: Value::Var(1),
            len: Value::Var(2),
            lanes: 8,
        };

        assert_eq!(instr.to_string(), "  %9 = tail_mask %1, %2 : 8");
        assert_eq!(instr.effect(), IrEffect::Pure);
    }

    #[test]
    fn tail_call_ir_pretty_prints_direct_target_args_and_return_type() {
        let instr = Instruction::TailCall {
            func: "fact_loop".into(),
            args: vec![Value::Var(3), Value::ConstI64(1)],
            ty: Type::I64,
        };

        assert_eq!(instr.to_string(), "  tailcall fact_loop(%3, 1) : i64");
        assert_eq!(instr.effect(), IrEffect::ControlFlow);
    }
}
