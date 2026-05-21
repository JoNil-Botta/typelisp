use crate::ir::*;
use crate::types::Type;
use std::collections::{HashMap, HashSet};

/// Optimization passes for the IR
pub struct Optimizer;

impl Optimizer {
    pub fn optimize(program: &mut Program) {
        for func in &mut program.functions {
            Self::optimize_function(func);
        }
    }

    fn optimize_function(func: &mut Function) {
        let mut changed = true;
        let mut iterations = 0;
        const MAX_ITERATIONS: usize = 10;

        while changed && iterations < MAX_ITERATIONS {
            changed = false;
            changed |= Self::constant_folding(func);
            changed |= Self::dead_code_elimination(func);
            changed |= Self::strength_reduction(func);
            changed |= Self::copy_propagation(func);
            iterations += 1;
        }
    }

    /// Constant folding: evaluate constant expressions at compile time
    fn constant_folding(func: &mut Function) -> bool {
        let mut changed = false;
        let mut constants: HashMap<VarId, Value> = HashMap::new();

        for block in &mut func.blocks {
            for instr in &mut block.instructions {
                match instr {
                    Instruction::BinOp { dst, op, lhs, rhs, ty } => {
                        let lhs_val = Self::resolve_value(lhs, &constants);
                        let rhs_val = Self::resolve_value(rhs, &constants);

                        if let (Some(l), Some(r)) = (lhs_val, rhs_val) {
                            if let Some(result) = Self::eval_binop(*op, l, r) {
                                let dst_id = *dst;
                                let result_ty = result.ty().unwrap_or_else(|| ty.clone());
                                let result_clone = result.clone();
                                *instr = Instruction::Mov {
                                    dst: dst_id,
                                    src: result,
                                    ty: result_ty,
                                };
                                constants.insert(dst_id, result_clone);
                                changed = true;
                                continue;
                            }
                        }

                        if let Value::Var(v) = lhs {
                            if let Some(c) = constants.get(v) {
                                *lhs = c.clone();
                                changed = true;
                            }
                        }
                        if let Value::Var(v) = rhs {
                            if let Some(c) = constants.get(v) {
                                *rhs = c.clone();
                                changed = true;
                            }
                        }
                    }
                    Instruction::UnOp { dst, op, src, ty } => {
                        let src_val = Self::resolve_value(src, &constants);
                        if let Some(s) = src_val {
                            if let Some(result) = Self::eval_unop(*op, s) {
                                let dst_id = *dst;
                                let result_ty = result.ty().unwrap_or_else(|| ty.clone());
                                let result_clone = result.clone();
                                *instr = Instruction::Mov {
                                    dst: dst_id,
                                    src: result,
                                    ty: result_ty,
                                };
                                constants.insert(dst_id, result_clone);
                                changed = true;
                                continue;
                            }
                        }

                        if let Value::Var(v) = src {
                            if let Some(c) = constants.get(v) {
                                *src = c.clone();
                                changed = true;
                            }
                        }
                    }
                    Instruction::Mov { dst, src, .. } => {
                        if let Value::Var(v) = src {
                            if let Some(c) = constants.get(v) {
                                *src = c.clone();
                                changed = true;
                            }
                        }
                        constants.insert(*dst, src.clone());
                    }
                    _ => {}
                }
            }
        }

        changed
    }

    fn resolve_value(val: &Value, constants: &HashMap<VarId, Value>) -> Option<Value> {
        match val {
            Value::Var(v) => constants.get(v).cloned(),
            _ => Some(val.clone()),
        }
    }

    fn eval_binop(op: BinOp, lhs: Value, rhs: Value) -> Option<Value> {
        match (op, lhs, rhs) {
            (BinOp::Add, Value::ConstI64(a), Value::ConstI64(b)) => Some(Value::ConstI64(a + b)),
            (BinOp::Sub, Value::ConstI64(a), Value::ConstI64(b)) => Some(Value::ConstI64(a - b)),
            (BinOp::Mul, Value::ConstI64(a), Value::ConstI64(b)) => Some(Value::ConstI64(a * b)),
            (BinOp::Div, Value::ConstI64(a), Value::ConstI64(b)) => {
                if b != 0 { Some(Value::ConstI64(a / b)) } else { None }
            }
            (BinOp::Mod, Value::ConstI64(a), Value::ConstI64(b)) => {
                if b != 0 { Some(Value::ConstI64(a % b)) } else { None }
            }
            (BinOp::Eq, Value::ConstI64(a), Value::ConstI64(b)) => Some(Value::ConstBool(a == b)),
            (BinOp::Ne, Value::ConstI64(a), Value::ConstI64(b)) => Some(Value::ConstBool(a != b)),
            (BinOp::Lt, Value::ConstI64(a), Value::ConstI64(b)) => Some(Value::ConstBool(a < b)),
            (BinOp::Le, Value::ConstI64(a), Value::ConstI64(b)) => Some(Value::ConstBool(a <= b)),
            (BinOp::Gt, Value::ConstI64(a), Value::ConstI64(b)) => Some(Value::ConstBool(a > b)),
            (BinOp::Ge, Value::ConstI64(a), Value::ConstI64(b)) => Some(Value::ConstBool(a >= b)),
            (BinOp::And, Value::ConstBool(a), Value::ConstBool(b)) => Some(Value::ConstBool(a && b)),
            (BinOp::Or, Value::ConstBool(a), Value::ConstBool(b)) => Some(Value::ConstBool(a || b)),
            (BinOp::Add, Value::ConstI32(a), Value::ConstI32(b)) => Some(Value::ConstI32(a + b)),
            (BinOp::Sub, Value::ConstI32(a), Value::ConstI32(b)) => Some(Value::ConstI32(a - b)),
            (BinOp::Mul, Value::ConstI32(a), Value::ConstI32(b)) => Some(Value::ConstI32(a * b)),
            (BinOp::Add, Value::ConstF64(a), Value::ConstF64(b)) => Some(Value::ConstF64(a + b)),
            (BinOp::Sub, Value::ConstF64(a), Value::ConstF64(b)) => Some(Value::ConstF64(a - b)),
            (BinOp::Mul, Value::ConstF64(a), Value::ConstF64(b)) => Some(Value::ConstF64(a * b)),
            (BinOp::Div, Value::ConstF64(a), Value::ConstF64(b)) => Some(Value::ConstF64(a / b)),
            _ => None,
        }
    }

    fn eval_unop(op: UnOp, src: Value) -> Option<Value> {
        match (op, src) {
            (UnOp::Neg, Value::ConstI64(a)) => Some(Value::ConstI64(-a)),
            (UnOp::Neg, Value::ConstI32(a)) => Some(Value::ConstI32(-a)),
            (UnOp::Neg, Value::ConstF64(a)) => Some(Value::ConstF64(-a)),
            (UnOp::Not, Value::ConstBool(a)) => Some(Value::ConstBool(!a)),
            _ => None,
        }
    }

    /// Dead code elimination: remove unused assignments
    fn dead_code_elimination(func: &mut Function) -> bool {
        let mut changed = false;

        // Collect all used variables
        let mut used: HashSet<VarId> = HashSet::new();
        for block in &func.blocks {
            for instr in &block.instructions {
                Self::collect_uses(instr, &mut used);
            }
        }

        // Remove unused pure computations
        for block in &mut func.blocks {
            block.instructions.retain(|instr| {
                let should_keep = match instr {
                    Instruction::BinOp { dst, .. }
                    | Instruction::UnOp { dst, .. }
                    | Instruction::Mov { dst, .. } => {
                        used.contains(dst) || Self::has_side_effects(instr)
                    }
                    _ => true,
                };
                if !should_keep {
                    changed = true;
                }
                should_keep
            });
        }

        changed
    }

    fn collect_uses(instr: &Instruction, used: &mut HashSet<VarId>) {
        match instr {
            Instruction::BinOp { lhs, rhs, .. } => {
                Self::add_value_uses(lhs, used);
                Self::add_value_uses(rhs, used);
            }
            Instruction::UnOp { src, .. } => Self::add_value_uses(src, used),
            Instruction::Mov { src, .. } => Self::add_value_uses(src, used),
            Instruction::Load { src, .. } => Self::add_value_uses(src, used),
            Instruction::Store { dst, src, .. } => {
                Self::add_value_uses(dst, used);
                Self::add_value_uses(src, used);
            }
            Instruction::Call { args, .. } => {
                for arg in args {
                    Self::add_value_uses(arg, used);
                }
            }
            Instruction::CallIndirect { func, args, .. } => {
                Self::add_value_uses(func, used);
                for arg in args {
                    Self::add_value_uses(arg, used);
                }
            }
            Instruction::Branch { cond, .. } => Self::add_value_uses(cond, used),
            Instruction::Return(Some(v)) => Self::add_value_uses(v, used),
            Instruction::Gep { base, offset, .. } => {
                Self::add_value_uses(base, used);
                Self::add_value_uses(offset, used);
            }
            Instruction::Phi { incoming, .. } => {
                for (val, _) in incoming {
                    Self::add_value_uses(val, used);
                }
            }
            _ => {}
        }
    }

    fn add_value_uses(val: &Value, used: &mut HashSet<VarId>) {
        if let Value::Var(v) = val {
            used.insert(*v);
        }
    }

    fn has_side_effects(instr: &Instruction) -> bool {
        matches!(
            instr,
            Instruction::Store { .. }
                | Instruction::Call { .. }
                | Instruction::CallIndirect { .. }
                | Instruction::Branch { .. }
                | Instruction::Jump(_)
                | Instruction::Return(_)
                | Instruction::Label(_)
        )
    }

    /// Strength reduction: replace expensive ops with cheaper ones
    fn strength_reduction(func: &mut Function) -> bool {
        let mut changed = false;

        for block in &mut func.blocks {
            for instr in &mut block.instructions {
                if let Instruction::BinOp { op, rhs, .. } = instr {
                    // x * 2 -> x + x, x * 1 -> x, etc.
                    if let Value::ConstI64(n) = rhs {
                        if *op == BinOp::Mul && *n == 2 {
                            // Could be replaced with shift or add
                            // For now, just mark as changed for future passes
                        }
                    }
                }
            }
        }

        changed
    }

    /// Copy propagation: replace uses of a copy with the original value
    fn copy_propagation(func: &mut Function) -> bool {
        let mut changed = false;
        let mut copies: HashMap<VarId, Value> = HashMap::new();

        for block in &mut func.blocks {
            for instr in &mut block.instructions {
                // First, try to substitute any Var uses with known copies
                Self::substitute_copies(instr, &copies);

                // Then, record new copies
                if let Instruction::Mov { dst, src, .. } = instr {
                    if let Value::Var(_) | Value::ConstI64(_) | Value::ConstI32(_) | Value::ConstBool(_) | Value::ConstF64(_) = src {
                        copies.insert(*dst, src.clone());
                    }
                }
            }
        }

        changed
    }

    fn substitute_copies(instr: &mut Instruction, copies: &HashMap<VarId, Value>) {
        let mut substitute = |val: &mut Value| {
            if let Value::Var(v) = val {
                if let Some(replacement) = copies.get(v) {
                    *val = replacement.clone();
                }
            }
        };

        match instr {
            Instruction::BinOp { lhs, rhs, .. } => {
                substitute(lhs);
                substitute(rhs);
            }
            Instruction::UnOp { src, .. } => substitute(src),
            Instruction::Mov { src, .. } => substitute(src),
            Instruction::Load { src, .. } => substitute(src),
            Instruction::Store { dst, src, .. } => {
                substitute(dst);
                substitute(src);
            }
            Instruction::Call { args, .. } => {
                for arg in args {
                    substitute(arg);
                }
            }
            Instruction::CallIndirect { func, args, .. } => {
                substitute(func);
                for arg in args {
                    substitute(arg);
                }
            }
            Instruction::Branch { cond, .. } => substitute(cond),
            Instruction::Return(Some(v)) => substitute(v),
            Instruction::Gep { base, offset, .. } => {
                substitute(base);
                substitute(offset);
            }
            Instruction::Phi { incoming, .. } => {
                for (val, _) in incoming {
                    substitute(val);
                }
            }
            _ => {}
        }
    }
}
