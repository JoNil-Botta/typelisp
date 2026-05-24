use super::block_successors;
use crate::ir::{Function, Instruction, Label, Value, VarId};
use std::collections::{BTreeSet, HashMap};

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct FunctionLiveness {
    pub(crate) blocks: Vec<BlockLiveness>,
    pub(crate) instruction_live_after: Vec<Vec<BTreeSet<VarId>>>,
    pub(crate) address_taken_vars: BTreeSet<VarId>,
}

impl FunctionLiveness {
    pub(crate) fn block(&self, label: &str) -> Option<&BlockLiveness> {
        self.blocks.iter().find(|block| block.label == label)
    }

    pub(crate) fn live_after(
        &self,
        label: &str,
        instruction_index: usize,
    ) -> Option<&BTreeSet<VarId>> {
        let block_index = self.blocks.iter().position(|block| block.label == label)?;
        self.instruction_live_after
            .get(block_index)?
            .get(instruction_index)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct BlockLiveness {
    pub(crate) label: Label,
    pub(crate) uses: BTreeSet<VarId>,
    pub(crate) defs: BTreeSet<VarId>,
    pub(crate) live_in: BTreeSet<VarId>,
    pub(crate) live_out: BTreeSet<VarId>,
}

pub(crate) fn analyze(func: &Function) -> FunctionLiveness {
    let mut blocks: Vec<BlockLiveness> = func
        .blocks
        .iter()
        .map(|block| {
            let (uses, defs) = block_use_def(&block.instructions);
            BlockLiveness {
                label: block.label.clone(),
                uses,
                defs,
                live_in: BTreeSet::new(),
                live_out: BTreeSet::new(),
            }
        })
        .collect();
    let label_index: HashMap<Label, usize> = func
        .blocks
        .iter()
        .enumerate()
        .map(|(idx, block)| (block.label.clone(), idx))
        .collect();

    loop {
        let mut changed = false;

        for block_index in (0..func.blocks.len()).rev() {
            let mut live_out = BTreeSet::new();
            for successor in block_successors(&func.blocks[block_index]) {
                let Some(successor_index) = label_index.get(&successor) else {
                    continue;
                };
                live_out.extend(blocks[*successor_index].live_in.iter().copied());
            }

            let mut live_in = blocks[block_index].uses.clone();
            for var in live_out.difference(&blocks[block_index].defs) {
                live_in.insert(*var);
            }

            if live_in != blocks[block_index].live_in || live_out != blocks[block_index].live_out {
                blocks[block_index].live_in = live_in;
                blocks[block_index].live_out = live_out;
                changed = true;
            }
        }

        if !changed {
            break;
        }
    }

    let instruction_live_after = func
        .blocks
        .iter()
        .enumerate()
        .map(|(block_index, block)| {
            let mut live = blocks[block_index].live_out.clone();
            let mut live_after = vec![BTreeSet::new(); block.instructions.len()];

            for instruction_index in (0..block.instructions.len()).rev() {
                let instr = &block.instructions[instruction_index];
                live_after[instruction_index] = live.clone();

                for def in instruction_defs(instr) {
                    live.remove(&def);
                }
                live.extend(instruction_uses(instr));
            }

            live_after
        })
        .collect();

    FunctionLiveness {
        blocks,
        instruction_live_after,
        address_taken_vars: address_taken_vars(func),
    }
}

fn block_use_def(instructions: &[Instruction]) -> (BTreeSet<VarId>, BTreeSet<VarId>) {
    let mut uses = BTreeSet::new();
    let mut defs = BTreeSet::new();

    for instr in instructions {
        for var in instruction_uses(instr) {
            if !defs.contains(&var) {
                uses.insert(var);
            }
        }
        defs.extend(instruction_defs(instr));
    }

    (uses, defs)
}

fn instruction_uses(instr: &Instruction) -> BTreeSet<VarId> {
    let mut uses = BTreeSet::new();

    match instr {
        Instruction::BinOp { lhs, rhs, .. }
        | Instruction::VectorBinOp { lhs, rhs, .. }
        | Instruction::VectorCompare { lhs, rhs, .. }
        | Instruction::MaskBinOp { lhs, rhs, .. } => {
            collect_value_vars(lhs, &mut uses);
            collect_value_vars(rhs, &mut uses);
        }
        Instruction::UnOp { src, .. }
        | Instruction::Mov { src, .. }
        | Instruction::Cast { src, .. }
        | Instruction::Load { src, .. }
        | Instruction::Branch { cond: src, .. }
        | Instruction::Splat { value: src, .. }
        | Instruction::VectorReduce { src, .. }
        | Instruction::MaskReduce { src, .. }
        | Instruction::MaskNot { src, .. } => {
            collect_value_vars(src, &mut uses);
        }
        Instruction::Store { dst, src, .. } => {
            collect_value_vars(dst, &mut uses);
            collect_value_vars(src, &mut uses);
        }
        Instruction::AddrOf { src, .. } => {
            uses.insert(*src);
        }
        Instruction::Call { args, .. } => {
            collect_value_slice_vars(args, &mut uses);
        }
        Instruction::TailSelfCall { args, .. } => {
            collect_value_slice_vars(args, &mut uses);
        }
        Instruction::CallIndirect { func, args, .. } => {
            collect_value_vars(func, &mut uses);
            collect_value_slice_vars(args, &mut uses);
        }
        Instruction::Return(Some(value)) => {
            collect_value_vars(value, &mut uses);
        }
        Instruction::Gep { base, offset, .. } => {
            collect_value_vars(base, &mut uses);
            collect_value_vars(offset, &mut uses);
        }
        Instruction::Select {
            mask,
            on_true,
            on_false,
            ..
        } => {
            collect_value_vars(mask, &mut uses);
            collect_value_vars(on_true, &mut uses);
            collect_value_vars(on_false, &mut uses);
        }
        Instruction::VectorLoad { base, index, .. } => {
            collect_value_vars(base, &mut uses);
            collect_value_vars(index, &mut uses);
        }
        Instruction::VectorStore {
            base, index, value, ..
        } => {
            collect_value_vars(base, &mut uses);
            collect_value_vars(index, &mut uses);
            collect_value_vars(value, &mut uses);
        }
        Instruction::PredicatedStore {
            base,
            index,
            value,
            mask,
            ..
        } => {
            collect_value_vars(base, &mut uses);
            collect_value_vars(index, &mut uses);
            collect_value_vars(value, &mut uses);
            collect_value_vars(mask, &mut uses);
        }
        Instruction::TailMask { index, len, .. } => {
            collect_value_vars(index, &mut uses);
            collect_value_vars(len, &mut uses);
        }
        Instruction::Phi { incoming, .. } => {
            for (value, _) in incoming {
                collect_value_vars(value, &mut uses);
            }
        }
        Instruction::Jump(_)
        | Instruction::Return(None)
        | Instruction::Alloc { .. }
        | Instruction::LaneId { .. } => {}
    }

    uses
}

fn instruction_defs(instr: &Instruction) -> BTreeSet<VarId> {
    let mut defs = BTreeSet::new();

    match instr {
        Instruction::BinOp { dst, .. }
        | Instruction::UnOp { dst, .. }
        | Instruction::Mov { dst, .. }
        | Instruction::Cast { dst, .. }
        | Instruction::Load { dst, .. }
        | Instruction::AddrOf { dst, .. }
        | Instruction::Gep { dst, .. }
        | Instruction::LaneId { dst, .. }
        | Instruction::Splat { dst, .. }
        | Instruction::VectorBinOp { dst, .. }
        | Instruction::VectorReduce { dst, .. }
        | Instruction::VectorCompare { dst, .. }
        | Instruction::MaskBinOp { dst, .. }
        | Instruction::MaskNot { dst, .. }
        | Instruction::MaskReduce { dst, .. }
        | Instruction::Select { dst, .. }
        | Instruction::VectorLoad { dst, .. }
        | Instruction::TailMask { dst, .. }
        | Instruction::Phi { dst, .. } => {
            defs.insert(*dst);
        }
        Instruction::Call { dst, .. } | Instruction::CallIndirect { dst, .. } => {
            if let Some(dst) = dst {
                defs.insert(*dst);
            }
        }
        Instruction::Alloc { var, .. } => {
            defs.insert(*var);
        }
        Instruction::Store { .. }
        | Instruction::VectorStore { .. }
        | Instruction::PredicatedStore { .. }
        | Instruction::TailSelfCall { .. }
        | Instruction::Branch { .. }
        | Instruction::Jump(_)
        | Instruction::Return(_) => {}
    }

    defs
}

fn address_taken_vars(func: &Function) -> BTreeSet<VarId> {
    let mut vars = BTreeSet::new();

    for block in &func.blocks {
        for instr in &block.instructions {
            if let Instruction::AddrOf { src, .. } = instr {
                vars.insert(*src);
            }
        }
    }

    vars
}

fn collect_value_slice_vars(values: &[Value], vars: &mut BTreeSet<VarId>) {
    for value in values {
        collect_value_vars(value, vars);
    }
}

fn collect_value_vars(value: &Value, vars: &mut BTreeSet<VarId>) {
    if let Value::Var(var) = value {
        vars.insert(*var);
    }
}
