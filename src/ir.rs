use crate::types::Type;

/// Intermediate Representation using a simple 3-address code form.
/// This is lowered from the AST and is the input to the optimizer and backend.

pub type VarId = u32;
pub type Label = String;

#[derive(Debug, Clone, PartialEq)]
pub enum Value {
    ConstI64(i64),
    ConstI32(i32),
    ConstI8(i8),
    ConstF64(f64),
    ConstBool(bool),
    ConstUnit,
    Var(VarId),
    Global(String),
}

#[derive(Debug, Clone, Copy, PartialEq)]
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
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum UnOp {
    Neg,
    Not,
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
    Mov {
        dst: VarId,
        src: Value,
        ty: Type,
    },
    /// Load from memory: dst = *src
    Load {
        dst: VarId,
        src: Value,
        ty: Type,
    },
    /// Store to memory: *dst = src
    Store {
        dst: Value,
        src: Value,
        ty: Type,
    },
    /// Get address of a variable: dst = &src
    AddrOf {
        dst: VarId,
        src: VarId,
    },
    /// Function call: dst = call func(args...)
    Call {
        dst: Option<VarId>,
        func: String,
        args: Vec<Value>,
        ty: Type,
    },
    /// Indirect call through function pointer
    CallIndirect {
        dst: Option<VarId>,
        func: Value,
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
    /// Label marker
    Label(Label),
    /// Allocate stack space for a local variable
    Alloc {
        var: VarId,
        ty: Type,
    },
    /// Get element pointer: dst = base[offset]
    Gep {
        dst: VarId,
        base: Value,
        offset: Value,
        elem_ty: Type,
    },
    /// Phi node for SSA: dst = phi [(val1, label1), (val2, label2), ...]
    Phi {
        dst: VarId,
        incoming: Vec<(Value, Label)>,
        ty: Type,
    },
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
            Value::Var(_) | Value::Global(_) => None, // Need type context
        }
    }
}
