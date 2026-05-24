use super::liveness::{self, FunctionLiveness};
use super::{BackendAbi, BackendArch, BackendOs, BackendTarget};
use crate::ir::{Function, Instruction, VarId};
use crate::types::Type;
use std::collections::{BTreeMap, BTreeSet};

const SYSV_CALLER_SAVED_INTEGER_REGS: [&str; 9] = [
    "%rax", "%rcx", "%rdx", "%rsi", "%rdi", "%r8", "%r9", "%r10", "%r11",
];
const SYSV_CALLEE_SAVED_INTEGER_REGS: [&str; 5] = ["%rbx", "%r12", "%r13", "%r14", "%r15"];
const SYSV_ALLOCATABLE_INTEGER_REGS: [&str; 14] = [
    "%rax", "%rcx", "%rdx", "%rsi", "%rdi", "%r8", "%r9", "%r10", "%r11", "%rbx", "%r12", "%r13",
    "%r14", "%r15",
];

const WIN64_CALLER_SAVED_INTEGER_REGS: [&str; 7] =
    ["%rax", "%rcx", "%rdx", "%r8", "%r9", "%r10", "%r11"];
const WIN64_CALLEE_SAVED_INTEGER_REGS: [&str; 7] =
    ["%rbx", "%rsi", "%rdi", "%r12", "%r13", "%r14", "%r15"];
const WIN64_ALLOCATABLE_INTEGER_REGS: [&str; 14] = [
    "%rax", "%rcx", "%rdx", "%r8", "%r9", "%r10", "%r11", "%rbx", "%rsi", "%rdi", "%r12", "%r13",
    "%r14", "%r15",
];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct TargetRegisterInfo {
    pub(crate) allocatable_integer: &'static [&'static str],
    pub(crate) caller_saved_integer: &'static [&'static str],
    pub(crate) callee_saved_integer: &'static [&'static str],
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct StackSlot {
    pub(crate) offset: i32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Location {
    Reg(&'static str),
    Spill(StackSlot),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct LiveInterval {
    pub(crate) start: usize,
    pub(crate) end: usize,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct RegPlan {
    pub(crate) assignments: BTreeMap<VarId, Location>,
    pub(crate) ineligible: BTreeSet<VarId>,
    pub(crate) intervals: BTreeMap<VarId, LiveInterval>,
}

#[derive(Debug, Clone, Copy)]
struct ActiveInterval {
    var: VarId,
    end: usize,
    reg: &'static str,
}

pub(crate) fn target_register_info(target: BackendTarget) -> TargetRegisterInfo {
    match (target.arch, target.os, target.abi) {
        (BackendArch::X86_64, BackendOs::Linux, BackendAbi::SystemV) => TargetRegisterInfo {
            allocatable_integer: &SYSV_ALLOCATABLE_INTEGER_REGS,
            caller_saved_integer: &SYSV_CALLER_SAVED_INTEGER_REGS,
            callee_saved_integer: &SYSV_CALLEE_SAVED_INTEGER_REGS,
        },
        (BackendArch::X86_64, BackendOs::Windows, BackendAbi::WindowsX64) => TargetRegisterInfo {
            allocatable_integer: &WIN64_ALLOCATABLE_INTEGER_REGS,
            caller_saved_integer: &WIN64_CALLER_SAVED_INTEGER_REGS,
            callee_saved_integer: &WIN64_CALLEE_SAVED_INTEGER_REGS,
        },
        _ => panic!("unsupported backend target: {:?}", target),
    }
}

pub(crate) fn plan(func: &Function, liveness: &FunctionLiveness, target: BackendTarget) -> RegPlan {
    let register_info = target_register_info(target);
    let var_types = function_var_types(func);
    let stack_slots = function_stack_slots(func);
    let intervals = live_intervals(func, liveness);
    let ineligible = ineligible_vars(func, liveness, &var_types);

    let mut assignments = BTreeMap::new();
    let mut active = Vec::new();
    let mut candidates: Vec<(VarId, LiveInterval)> = intervals
        .iter()
        .filter_map(|(var, interval)| {
            if ineligible.contains(var) {
                None
            } else if var_types.contains_key(var) {
                Some((*var, *interval))
            } else {
                None
            }
        })
        .collect();
    candidates.sort_by_key(|(var, interval)| (interval.start, interval.end, *var));

    for (var, interval) in candidates {
        expire_old_intervals(&mut active, interval.start);

        if active.len() == register_info.allocatable_integer.len() {
            spill_at_interval(var, interval, &mut active, &mut assignments, &stack_slots);
        } else {
            let reg = first_free_register(register_info.allocatable_integer, &active);
            assignments.insert(var, Location::Reg(reg));
            active.push(ActiveInterval {
                var,
                end: interval.end,
                reg,
            });
            sort_active(&mut active);
        }
    }

    RegPlan {
        assignments,
        ineligible,
        intervals,
    }
}

fn function_var_types(func: &Function) -> BTreeMap<VarId, Type> {
    func.params
        .iter()
        .chain(func.locals.iter())
        .map(|(var, ty)| (*var, ty.clone()))
        .collect()
}

fn function_stack_slots(func: &Function) -> BTreeMap<VarId, StackSlot> {
    let mut stack_size = 0;
    let mut slots = BTreeMap::new();

    for (var, ty) in func.params.iter().chain(func.locals.iter()) {
        let size = ty.size() as i32;
        let align = ty.align() as i32;
        stack_size = (stack_size + align - 1) & !(align - 1);
        stack_size += size;
        slots.insert(
            *var,
            StackSlot {
                offset: -stack_size,
            },
        );
    }

    slots
}

fn live_intervals(func: &Function, liveness: &FunctionLiveness) -> BTreeMap<VarId, LiveInterval> {
    let mut intervals = BTreeMap::new();
    let mut point = 0;

    for block in &func.blocks {
        for (instruction_index, instr) in block.instructions.iter().enumerate() {
            for var in liveness::instruction_defs(instr) {
                extend_interval(&mut intervals, var, point);
            }
            for var in liveness::instruction_uses(instr) {
                extend_interval(&mut intervals, var, point);
            }
            if let Some(live_after) = liveness.live_after(&block.label, instruction_index) {
                for var in live_after {
                    extend_interval(&mut intervals, *var, point + 1);
                }
            }
            point += 2;
        }
    }

    intervals
}

fn extend_interval(intervals: &mut BTreeMap<VarId, LiveInterval>, var: VarId, point: usize) {
    intervals
        .entry(var)
        .and_modify(|interval| {
            interval.start = interval.start.min(point);
            interval.end = interval.end.max(point);
        })
        .or_insert(LiveInterval {
            start: point,
            end: point,
        });
}

fn ineligible_vars(
    func: &Function,
    liveness: &FunctionLiveness,
    var_types: &BTreeMap<VarId, Type>,
) -> BTreeSet<VarId> {
    let mut vars = BTreeSet::new();

    for (var, ty) in var_types {
        if !is_regalloc_scalar_type(ty) {
            vars.insert(*var);
        }
    }
    vars.extend(liveness.address_taken_vars.iter().copied());
    vars.extend(call_live_vars(func, liveness));
    vars.extend(unsupported_def_vars(func));

    vars
}

fn is_regalloc_scalar_type(ty: &Type) -> bool {
    matches!(
        ty,
        Type::I64
            | Type::U64
            | Type::I32
            | Type::U32
            | Type::I16
            | Type::U16
            | Type::I8
            | Type::U8
            | Type::Bool
            | Type::Char
            | Type::Func(_, _)
    )
}

fn call_live_vars(func: &Function, liveness: &FunctionLiveness) -> BTreeSet<VarId> {
    let mut vars = BTreeSet::new();

    for block in &func.blocks {
        for (instruction_index, instr) in block.instructions.iter().enumerate() {
            match instr {
                Instruction::Call { .. } | Instruction::CallIndirect { .. } => {
                    let Some(live_after) = liveness.live_after(&block.label, instruction_index)
                    else {
                        continue;
                    };
                    vars.extend(live_after.iter().copied());
                }
                _ => {}
            }
        }
    }

    vars
}

fn unsupported_def_vars(func: &Function) -> BTreeSet<VarId> {
    let mut vars = BTreeSet::new();

    for block in &func.blocks {
        for instr in &block.instructions {
            match instr {
                Instruction::LaneId { dst, .. }
                | Instruction::Splat { dst, .. }
                | Instruction::VectorBinOp { dst, .. }
                | Instruction::VectorCompare { dst, .. }
                | Instruction::MaskBinOp { dst, .. }
                | Instruction::MaskNot { dst, .. }
                | Instruction::Select { dst, .. }
                | Instruction::VectorLoad { dst, .. }
                | Instruction::TailMask { dst, .. } => {
                    vars.insert(*dst);
                }
                _ => {}
            }
        }
    }

    vars
}

fn expire_old_intervals(active: &mut Vec<ActiveInterval>, start: usize) {
    active.retain(|active| active.end >= start);
    sort_active(active);
}

fn first_free_register(
    registers: &'static [&'static str],
    active: &[ActiveInterval],
) -> &'static str {
    registers
        .iter()
        .copied()
        .find(|reg| !active.iter().any(|active| active.reg == *reg))
        .expect("register pool must not be exhausted")
}

fn spill_at_interval(
    var: VarId,
    interval: LiveInterval,
    active: &mut [ActiveInterval],
    assignments: &mut BTreeMap<VarId, Location>,
    stack_slots: &BTreeMap<VarId, StackSlot>,
) {
    let spill_index = active
        .iter()
        .enumerate()
        .max_by_key(|(_, active)| (active.end, active.var))
        .map(|(index, _)| index)
        .expect("active set is full");
    let spill = active[spill_index];

    if spill.end > interval.end {
        assignments.insert(spill.var, Location::Spill(stack_slots[&spill.var]));
        assignments.insert(var, Location::Reg(spill.reg));
        active[spill_index] = ActiveInterval {
            var,
            end: interval.end,
            reg: spill.reg,
        };
        sort_active(active);
    } else {
        assignments.insert(var, Location::Spill(stack_slots[&var]));
    }
}

fn sort_active(active: &mut [ActiveInterval]) {
    active.sort_by_key(|active| (active.end, active.var));
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ir::{BasicBlock, Value};

    fn block(instructions: Vec<Instruction>) -> BasicBlock {
        BasicBlock {
            label: "entry".into(),
            instructions,
        }
    }

    fn function(
        params: Vec<(VarId, Type)>,
        locals: Vec<(VarId, Type)>,
        instructions: Vec<Instruction>,
    ) -> Function {
        Function {
            name: "f".into(),
            params,
            ret: Type::Unit,
            locals,
            blocks: vec![block(instructions)],
            entry: "entry".into(),
        }
    }

    fn plan_for(func: &Function, target: BackendTarget) -> RegPlan {
        let liveness = liveness::analyze(func);
        plan(func, &liveness, target)
    }

    #[test]
    fn filters_non_scalar_and_address_taken_vars() {
        let func = function(
            vec![(0, Type::I64)],
            vec![
                (1, Type::F64),
                (2, Type::String),
                (3, Type::I64),
                (4, Type::Vector(Box::new(Type::I64), 4)),
                (5, Type::U64),
            ],
            vec![
                Instruction::Mov {
                    dst: 3,
                    src: Value::Var(0),
                    ty: Type::I64,
                },
                Instruction::AddrOf { dst: 5, src: 3 },
                Instruction::Return(Some(Value::Var(3))),
            ],
        );

        let plan = plan_for(&func, BackendTarget::linux_x86_64_system_v());

        assert!(plan.ineligible.contains(&1));
        assert!(plan.ineligible.contains(&2));
        assert!(plan.ineligible.contains(&3));
        assert!(plan.ineligible.contains(&4));
        assert!(!plan.assignments.contains_key(&1));
        assert!(!plan.assignments.contains_key(&2));
        assert!(!plan.assignments.contains_key(&3));
        assert!(!plan.assignments.contains_key(&4));
        assert_eq!(plan.assignments.get(&0), Some(&Location::Reg("%rax")));
    }

    #[test]
    fn excludes_vars_live_after_calls() {
        let func = function(
            vec![(0, Type::I64)],
            vec![(1, Type::I64), (2, Type::I64)],
            vec![
                Instruction::Mov {
                    dst: 1,
                    src: Value::Var(0),
                    ty: Type::I64,
                },
                Instruction::Call {
                    dst: None,
                    func: "side_effect".into(),
                    args: vec![],
                    ty: Type::Unit,
                },
                Instruction::Mov {
                    dst: 2,
                    src: Value::Var(1),
                    ty: Type::I64,
                },
                Instruction::Return(Some(Value::Var(2))),
            ],
        );

        let plan = plan_for(&func, BackendTarget::linux_x86_64_system_v());

        assert!(plan.ineligible.contains(&1));
        assert!(!plan.assignments.contains_key(&1));
        assert!(matches!(plan.assignments.get(&0), Some(Location::Reg(_))));
        assert!(matches!(plan.assignments.get(&2), Some(Location::Reg(_))));
    }

    #[test]
    fn overlapping_ranges_force_spill_deterministically() {
        let mut locals = Vec::new();
        let mut instructions = Vec::new();

        for var in 0..15 {
            locals.push((var, Type::I64));
            instructions.push(Instruction::Mov {
                dst: var,
                src: Value::ConstI64(var as i64),
                ty: Type::I64,
            });
        }
        for var in 0..15 {
            instructions.push(Instruction::Store {
                dst: Value::Global(format!("g{var}")),
                src: Value::Var(var),
                ty: Type::I64,
            });
        }
        instructions.push(Instruction::Return(None));

        let func = function(vec![], locals, instructions);
        let plan = plan_for(&func, BackendTarget::linux_x86_64_system_v());
        let spills: Vec<_> = plan
            .assignments
            .iter()
            .filter_map(|(var, location)| match location {
                Location::Spill(slot) => Some((*var, *slot)),
                Location::Reg(_) => None,
            })
            .collect();

        assert_eq!(plan.assignments.len(), 15);
        assert_eq!(spills.len(), 1);
        assert_eq!(spills[0].0, 14);
        assert!(spills[0].1.offset < 0);
    }

    #[test]
    fn excludes_values_defined_by_vector_or_mask_ops() {
        let func = function(
            vec![],
            vec![(0, Type::I64)],
            vec![
                Instruction::LaneId {
                    dst: 0,
                    lanes: 4,
                    ty: Type::I64,
                },
                Instruction::Return(Some(Value::Var(0))),
            ],
        );

        let plan = plan_for(&func, BackendTarget::linux_x86_64_system_v());

        assert!(plan.ineligible.contains(&0));
        assert!(!plan.assignments.contains_key(&0));
    }

    #[test]
    fn register_info_models_system_v_and_windows_clobbers() {
        let sysv = target_register_info(BackendTarget::linux_x86_64_system_v());
        let win64 = target_register_info(BackendTarget::windows_x86_64());

        assert!(sysv.caller_saved_integer.contains(&"%rdi"));
        assert!(!sysv.callee_saved_integer.contains(&"%rdi"));
        assert!(win64.callee_saved_integer.contains(&"%rdi"));
        assert!(!win64.caller_saved_integer.contains(&"%rdi"));
        assert_ne!(sysv.allocatable_integer, win64.allocatable_integer);
    }
}
