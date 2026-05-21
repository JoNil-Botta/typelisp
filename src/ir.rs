#![allow(dead_code)]

use crate::types::Type;
use std::fmt;

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
    Mov { dst: VarId, src: Value, ty: Type },
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
    Alloc { var: VarId, ty: Type },
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

impl fmt::Display for Value {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Value::ConstI64(n) => write!(f, "{}", n),
            Value::ConstI32(n) => write!(f, "{}", n),
            Value::ConstI8(n) => write!(f, "{}", n),
            Value::ConstF64(n) => write!(f, "{}", n),
            Value::ConstBool(b) => write!(f, "{}", b),
            Value::ConstUnit => write!(f, "unit"),
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
        };
        write!(f, "{}", s)
    }
}

impl fmt::Display for UnOp {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let s = match self {
            UnOp::Neg => "neg",
            UnOp::Not => "not",
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
            Instruction::Label(label) => {
                write!(f, "{}:", label)
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
