#![allow(dead_code)]

use crate::ir::{
    BasicBlock, BinOp as IrBinOp, Function, Instruction, Label, Program, UnOp as IrUnOp, Value,
    VarId,
};
use crate::types::Type;
use std::collections::{HashMap, HashSet};

/// x86_64 assembly code generator
/// Target: Linux, System V AMD64 ABI
pub struct X86_64Backend {
    output: String,
    label_counter: u32,
    stack_size: i32,
    var_offsets: HashMap<VarId, i32>,
    var_types: HashMap<VarId, Type>,
    return_ty: Type,
    /// VarIds that are function parameters of the function currently being
    /// generated. Their `Alloc` instructions are no-ops because the parameter
    /// stack slot is materialized by the prologue.
    param_vars: HashSet<VarId>,
    /// Mangled symbol name of the function currently being generated. Used to
    /// build the per-block GAS labels (`{fn}.{block}`) that `Branch`/`Jump`
    /// target — the IR carries bare block labels (e.g. `then.0`) which must be
    /// qualified with the function symbol to resolve.
    current_fn: String,
}

/// Validate that an IR program only uses constructs the backend can faithfully
/// lower. The backend currently supports scalar arithmetic, unary/binary ops,
/// comparisons, direct calls, `return`, control flow (`if`/`while` via
/// `Branch`/`Jump`/`Phi`) and scalar `let`/`set!` locals (`Alloc`/`Store`/`Load`
/// against a local's stack slot) over integer/bool/char/f64 scalars.
///
/// Constructs that are lowered but NOT yet selected to assembly (f32 values,
/// address/GEP pointer arithmetic and `Global` operands)
/// are rejected here with a clear message instead of being silently
/// miscompiled (they would otherwise fall through to a `# TODO` comment and
/// produce wrong code).
pub fn validate_program(program: &Program) -> Result<(), String> {
    if program.functions.is_empty() {
        return Err("backend: program defines no functions to compile".into());
    }
    for func in &program.functions {
        validate_function(func)?;
    }
    Ok(())
}

fn validate_function(func: &Function) -> Result<(), String> {
    let var_types: HashMap<VarId, Type> = func
        .params
        .iter()
        .chain(func.locals.iter())
        .map(|(var, ty)| (*var, ty.clone()))
        .collect();

    let unsupported = |what: &str| {
        Err(format!(
            "backend: function '{}' uses an unsupported construct ({}). \
             The x86_64 backend currently supports scalar arithmetic, comparisons, \
             unary/binary operators, direct function calls, recursion, control flow \
             (if/while), indirect calls through function-pointer values and scalar \
             let/set! locals. F32 values, tuples, arrays, lambdas and strings are \
             not yet wired (see #13).",
            func.name, what
        ))
    };

    for block in &func.blocks {
        for instr in &block.instructions {
            match instr {
                // Fully supported scalar instructions.
                Instruction::BinOp {
                    op, lhs, rhs, ty, ..
                } => {
                    check_operand(lhs).map_err(|w| unsupported_value(&func.name, &w))?;
                    check_operand(rhs).map_err(|w| unsupported_value(&func.name, &w))?;
                    let lhs_ty = validate_value_type(lhs, &var_types).unwrap_or_else(|| ty.clone());
                    let rhs_ty = validate_value_type(rhs, &var_types).unwrap_or_else(|| ty.clone());
                    if (lhs_ty == Type::F64 || rhs_ty == Type::F64 || *ty == Type::F64)
                        && matches!(
                            *op,
                            IrBinOp::Mod
                                | IrBinOp::And
                                | IrBinOp::Or
                                | IrBinOp::BitAnd
                                | IrBinOp::BitOr
                                | IrBinOp::BitXor
                                | IrBinOp::Shl
                                | IrBinOp::Shr
                        )
                    {
                        return unsupported("unsupported f64 binary operator");
                    }
                }
                Instruction::UnOp { op, src, ty, .. } => {
                    check_operand(src).map_err(|w| unsupported_value(&func.name, &w))?;
                    let src_ty = validate_value_type(src, &var_types).unwrap_or_else(|| ty.clone());
                    if src_ty == Type::F64 && matches!(*op, IrUnOp::Not | IrUnOp::BitNot) {
                        return unsupported("unsupported f64 unary operator");
                    }
                }
                Instruction::Mov { src, .. } => {
                    check_operand(src).map_err(|w| unsupported_value(&func.name, &w))?;
                }
                Instruction::Cast {
                    src,
                    from_ty,
                    to_ty,
                    ..
                } => {
                    check_operand(src).map_err(|w| unsupported_value(&func.name, &w))?;
                    if from_ty.is_float() || to_ty.is_float() {
                        return unsupported("floating-point cast");
                    }
                }
                Instruction::Call { args, .. } => {
                    for arg in args {
                        check_operand(arg).map_err(|w| unsupported_value(&func.name, &w))?;
                    }
                }
                Instruction::Return(Some(v)) => {
                    check_operand(v).map_err(|w| unsupported_value(&func.name, &w))?;
                }
                Instruction::Return(None) | Instruction::Label(_) | Instruction::Jump(_) => {}
                // `if`/`while` control flow — now codegen'd.
                Instruction::Branch { cond, .. } => {
                    check_operand(cond).map_err(|w| unsupported_value(&func.name, &w))?;
                }
                // `if` result selection — eliminated to predecessor copies before
                // codegen (see `eliminate_phis`).
                Instruction::Phi { incoming, .. } => {
                    for (val, _) in incoming {
                        check_operand(val).map_err(|w| unsupported_value(&func.name, &w))?;
                    }
                }
                // `let`/`set!` scalar locals. `Alloc` reserves a stack slot
                // (parameter `Alloc`s are prologue no-ops); `Store`/`Load` move
                // between the local's slot and a register. Only direct
                // variable-slot addresses are supported (`Value::Var`); general
                // pointer/computed addresses are deferred to the GEP/array work.
                Instruction::Alloc { .. } => {}
                Instruction::Load { src, .. } => {
                    match src {
                        Value::Var(_) => {}
                        _ => return unsupported("load through a non-local address"),
                    }
                    check_operand(src).map_err(|w| unsupported_value(&func.name, &w))?;
                }
                Instruction::Store { dst, src, .. } => {
                    match dst {
                        Value::Var(_) => {}
                        _ => return unsupported("store through a non-local address"),
                    }
                    check_operand(src).map_err(|w| unsupported_value(&func.name, &w))?;
                }
                Instruction::CallIndirect {
                    func: target, args, ..
                } => {
                    match target {
                        Value::Var(var) => {
                            if !matches!(var_types.get(var), Some(Type::Func(_, _))) {
                                return unsupported("indirect call through a non-function value");
                            }
                        }
                        _ => return unsupported("indirect call through a non-local value"),
                    }
                    for arg in args {
                        check_operand(arg).map_err(|w| unsupported_value(&func.name, &w))?;
                    }
                }
                Instruction::AddrOf { .. } => return unsupported("address-of"),
                Instruction::Gep { .. } => return unsupported("get-element-pointer"),
            }
        }
    }
    Ok(())
}

/// Reject operand kinds the code generator cannot materialize.
fn check_operand(val: &Value) -> Result<(), String> {
    match val {
        Value::ConstI64(_)
        | Value::ConstI32(_)
        | Value::ConstI8(_)
        | Value::ConstF64(_)
        | Value::ConstBool(_)
        | Value::Var(_) => Ok(()),
        Value::ConstUnit => Err("unit value".into()),
        Value::Global(name) => Err(format!("global/unresolved reference '{}'", name)),
    }
}

fn validate_value_type(val: &Value, var_types: &HashMap<VarId, Type>) -> Option<Type> {
    match val {
        Value::ConstI64(_) => Some(Type::I64),
        Value::ConstI32(_) => Some(Type::I32),
        Value::ConstI8(_) => Some(Type::I8),
        Value::ConstF64(_) => Some(Type::F64),
        Value::ConstBool(_) => Some(Type::Bool),
        Value::ConstUnit => Some(Type::Unit),
        Value::Var(var) => var_types.get(var).cloned(),
        Value::Global(_) => None,
    }
}

fn unsupported_value(func: &str, what: &str) -> String {
    format!(
        "backend: function '{}' uses an unsupported operand ({}). \
         The x86_64 backend currently supports integer, bool, char and f64 scalars only.",
        func, what
    )
}

/// The successor block labels of a basic block, derived from its terminator.
fn block_successors(block: &BasicBlock) -> Vec<Label> {
    match block.instructions.last() {
        Some(Instruction::Branch {
            true_label,
            false_label,
            ..
        }) => vec![true_label.clone(), false_label.clone()],
        Some(Instruction::Jump(l)) => vec![l.clone()],
        _ => Vec::new(),
    }
}

/// Eliminate SSA `Phi` nodes by converting them to copies in predecessor
/// blocks (the classic "phi → moves in predecessors" lowering).
///
/// A `Phi { dst, incoming: [(val, src_label), ..] }` at the head of a merge
/// block selects `val` when control arrives from the predecessor associated
/// with `src_label`. We materialize that by inserting `dst = mov val` at the
/// end of the predecessor block (immediately before its terminating
/// branch/jump), then deleting the `Phi`. `dst` already has a stack slot
/// reserved by the function frame (the lowerer records every phi result in
/// `func.locals`), so the copy is a plain slot write at codegen time.
///
/// The label recorded in a phi's incoming edge marks the *entry* of the
/// branch region, which for nested control flow is not necessarily the block
/// that actually jumps to the merge (e.g. an `if` whose arm is itself an
/// `if`). We therefore follow the successor edges from the recorded label to
/// the first reachable block that has the merge block as a successor — that is
/// the true predecessor where the copy must live.
fn eliminate_phis(func: &Function) -> Function {
    let mut func = func.clone();

    // label -> block index
    let label_idx: std::collections::HashMap<Label, usize> = func
        .blocks
        .iter()
        .enumerate()
        .map(|(i, b)| (b.label.clone(), i))
        .collect();

    // Successor labels per block index.
    let successors: Vec<Vec<Label>> = func.blocks.iter().map(block_successors).collect();

    // Planned copies: predecessor block index -> moves to insert before its
    // terminator, in source order.
    let mut inserts: std::collections::HashMap<usize, Vec<Instruction>> =
        std::collections::HashMap::new();

    for merge_idx in 0..func.blocks.len() {
        let merge_label = func.blocks[merge_idx].label.clone();
        // Collect this block's phis (they sit at the head of the merge block).
        let phis: Vec<Instruction> = func.blocks[merge_idx]
            .instructions
            .iter()
            .filter(|i| matches!(i, Instruction::Phi { .. }))
            .cloned()
            .collect();

        for phi in &phis {
            let Instruction::Phi { dst, incoming, ty } = phi else {
                continue;
            };
            for (val, src_label) in incoming {
                let Some(pred_idx) =
                    find_predecessor(src_label, &merge_label, &label_idx, &successors)
                else {
                    // No reachable predecessor jumps to the merge (should not
                    // happen for well-formed lowering); skip rather than panic.
                    continue;
                };
                inserts.entry(pred_idx).or_default().push(Instruction::Mov {
                    dst: *dst,
                    src: val.clone(),
                    ty: ty.clone(),
                });
            }
        }
    }

    // Drop all phi instructions.
    for block in &mut func.blocks {
        block
            .instructions
            .retain(|i| !matches!(i, Instruction::Phi { .. }));
    }

    // Insert the planned copies immediately before each predecessor's
    // terminator (the last instruction, which is a Branch/Jump).
    for (pred_idx, moves) in inserts {
        let block = &mut func.blocks[pred_idx];
        let insert_at = if block.instructions.is_empty() {
            0
        } else {
            // Before the terminating branch/jump.
            match block.instructions.last() {
                Some(Instruction::Branch { .. }) | Some(Instruction::Jump(_)) => {
                    block.instructions.len() - 1
                }
                _ => block.instructions.len(),
            }
        };
        for (offset, mv) in moves.into_iter().enumerate() {
            block.instructions.insert(insert_at + offset, mv);
        }
    }

    func
}

/// From the branch-region entry `start_label`, follow successor edges to the
/// first reachable block (including the start) whose successors include
/// `merge_label`. Returns that block's index — the true predecessor of the
/// merge block on this path.
fn find_predecessor(
    start_label: &str,
    merge_label: &str,
    label_idx: &std::collections::HashMap<Label, usize>,
    successors: &[Vec<Label>],
) -> Option<usize> {
    let start = *label_idx.get(start_label)?;
    let mut stack = vec![start];
    let mut seen = HashSet::new();
    while let Some(idx) = stack.pop() {
        if !seen.insert(idx) {
            continue;
        }
        if successors[idx].iter().any(|l| l == merge_label) {
            return Some(idx);
        }
        for succ in &successors[idx] {
            if let Some(&j) = label_idx.get(succ) {
                stack.push(j);
            }
        }
    }
    None
}

impl X86_64Backend {
    pub fn new() -> Self {
        X86_64Backend {
            output: String::new(),
            label_counter: 0,
            stack_size: 0,
            var_offsets: HashMap::new(),
            var_types: HashMap::new(),
            return_ty: Type::Unit,
            param_vars: HashSet::new(),
            current_fn: String::new(),
        }
    }

    pub fn generate(&mut self, program: &Program) -> String {
        self.emit("    .text");
        self.emit("    .globl main");
        self.emit("    .globl _start");
        self.emit("");

        // Generate extern declarations
        for (name, _) in &program.externs {
            self.emit(&format!("    .extern {}", Self::mangle_name(name)));
        }
        self.emit("");

        // Generate functions
        for func in &program.functions {
            self.generate_function(func);
        }

        // Generate main if not present
        if !program.functions.iter().any(|f| f.name == "main") {
            self.emit("main:");
            self.emit("    xor %eax, %eax");
            self.emit("    ret");
        }

        self.emit("");
        self.emit("_start:");
        self.emit("    call main");
        self.emit("    movq %rax, %rdi");
        self.emit("    movq $60, %rax");
        self.emit("    syscall");

        self.output.clone()
    }

    fn generate_function(&mut self, func: &Function) {
        let name = Self::mangle_name(&func.name);
        self.current_fn = name.clone();
        self.emit(&format!("{}:", name));

        // Eliminate SSA `Phi` nodes by inserting copies into the Phi's stack
        // slot at the end of each predecessor block. After this pass the IR
        // contains no `Phi` instructions and can be selected directly.
        let func = eliminate_phis(func);
        let func = &func;

        // Prologue
        self.emit("    push %rbp");
        self.emit("    mov %rsp, %rbp");

        // Calculate stack frame
        self.stack_size = 0;
        self.var_offsets.clear();
        self.var_types.clear();
        self.return_ty = func.ret.clone();
        self.param_vars = func.params.iter().map(|(v, _)| *v).collect();

        // Allocate space for parameters (so their Alloc no-ops have a slot) and
        // locals.
        for (var, ty) in func.params.iter().chain(func.locals.iter()) {
            let size = ty.size() as i32;
            let align = ty.align() as i32;
            self.stack_size = (self.stack_size + align - 1) & !(align - 1);
            self.stack_size += size;
            self.var_offsets.insert(*var, -self.stack_size);
            self.var_types.insert(*var, ty.clone());
        }

        // Align stack to 16 bytes
        self.stack_size = (self.stack_size + 15) & !15;

        if self.stack_size > 0 {
            self.emit(&format!("    sub ${}, %rsp", self.stack_size));
        }

        // Move parameters to stack slots. Each argument register is written at
        // the width of its declared type, so a narrow parameter does not clobber
        // adjacent slots. The sub-register names differ per register
        // (`%rdi`->`%edi`/`%di`/`%dil`), so we look them up rather than string
        // -slicing the 64-bit name.
        let param_regs = ["%rdi", "%rsi", "%rdx", "%rcx", "%r8", "%r9"];
        let xmm_regs = [
            "%xmm0", "%xmm1", "%xmm2", "%xmm3", "%xmm4", "%xmm5", "%xmm6", "%xmm7",
        ];
        // System V AMD64: integer and floating-point arguments consume
        // *independent* register sequences, so we track two counters. Each
        // argument register is written at the width of its declared type so a
        // narrow parameter does not clobber adjacent slots.
        let mut int_param = 0;
        let mut float_param = 0;
        for (var, ty) in &func.params {
            let offset = self.var_offsets[var];
            match ty {
                Type::I64 | Type::U64 | Type::Func(_, _) => {
                    if int_param < param_regs.len() {
                        self.emit(&format!(
                            "    movq {}, {}(%rbp)",
                            param_regs[int_param], offset
                        ));
                    }
                    int_param += 1;
                }
                Type::I32 | Type::U32 => {
                    if int_param < param_regs.len() {
                        self.emit(&format!(
                            "    movl {}, {}(%rbp)",
                            Self::gpr32(param_regs[int_param]),
                            offset
                        ));
                    }
                    int_param += 1;
                }
                Type::I16 | Type::U16 => {
                    if int_param < param_regs.len() {
                        self.emit(&format!(
                            "    movw {}, {}(%rbp)",
                            Self::gpr16(param_regs[int_param]),
                            offset
                        ));
                    }
                    int_param += 1;
                }
                Type::I8 | Type::U8 | Type::Bool | Type::Char => {
                    if int_param < param_regs.len() {
                        self.emit(&format!(
                            "    movb {}, {}(%rbp)",
                            Self::gpr8(param_regs[int_param]),
                            offset
                        ));
                    }
                    int_param += 1;
                }
                Type::F64 => {
                    if float_param < xmm_regs.len() {
                        self.emit(&format!(
                            "    movsd {}, {}(%rbp)",
                            xmm_regs[float_param], offset
                        ));
                    }
                    float_param += 1;
                }
                _ => {}
            }
        }

        // Generate basic blocks
        for block in &func.blocks {
            self.emit(&format!("{}.{}:", name, block.label));
            for instr in &block.instructions {
                self.generate_instruction(instr);
            }
        }
    }

    fn generate_instruction(&mut self, instr: &Instruction) {
        match instr {
            Instruction::Label(label) => {
                self.emit(&format!("{}:", label));
            }
            // Parameter slots are materialized by the prologue; their Alloc is a
            // no-op here. (Non-parameter Allocs are rejected by validation.)
            Instruction::Alloc { .. } => {}
            Instruction::Mov { dst, src, ty } => {
                let dst_offset = self.var_offsets[dst];
                if *ty == Type::F64 {
                    self.load_value(src, "%xmm0", ty);
                    self.store_xmm_value("%xmm0", dst_offset);
                    return;
                }

                match (src, ty) {
                    (Value::ConstI64(n), _) => {
                        self.emit(&format!("    movq ${}, {}(%rbp)", n, dst_offset));
                    }
                    (Value::ConstI32(n), _) => {
                        self.emit(&format!("    movl ${}, {}(%rbp)", n, dst_offset));
                    }
                    (Value::ConstI8(n), _) => {
                        self.emit(&format!("    movb ${}, {}(%rbp)", n, dst_offset));
                    }
                    (Value::ConstBool(b), _) => {
                        let n = if *b { 1 } else { 0 };
                        self.emit(&format!("    movb ${}, {}(%rbp)", n, dst_offset));
                    }
                    (Value::ConstF64(n), _) => {
                        // Load float from constant pool (simplified)
                        self.emit(&format!("    movabsq ${:#x}, %rax", n.to_bits()));
                        self.emit(&format!("    movq %rax, {}(%rbp)", dst_offset));
                    }
                    (Value::Var(src_var), _) => {
                        let src_offset = self.var_offsets[src_var];
                        match ty.size() {
                            8 => {
                                self.emit(&format!("    movq {}(%rbp), %rax", src_offset));
                                self.emit(&format!("    movq %rax, {}(%rbp)", dst_offset));
                            }
                            4 => {
                                self.emit(&format!("    movl {}(%rbp), %eax", src_offset));
                                self.emit(&format!("    movl %eax, {}(%rbp)", dst_offset));
                            }
                            2 => {
                                self.emit(&format!("    movw {}(%rbp), %ax", src_offset));
                                self.emit(&format!("    movw %ax, {}(%rbp)", dst_offset));
                            }
                            1 => {
                                self.emit(&format!("    movb {}(%rbp), %al", src_offset));
                                self.emit(&format!("    movb %al, {}(%rbp)", dst_offset));
                            }
                            _ => {}
                        }
                    }
                    _ => {}
                }
            }
            // Width/sign conversion. Load the source extended per its *source*
            // type (sign-extend signed, zero-extend unsigned), which is exactly
            // the widening semantics; for narrowing we then keep only the low
            // `to_ty` bytes when writing the destination slot. The destination
            // slot is sized by `to_ty` (recorded in the frame), so the store
            // width below truncates as required.
            Instruction::Cast {
                dst,
                src,
                from_ty,
                to_ty,
            } => {
                let dst_offset = self.var_offsets[dst];
                self.load_value(src, "%rax", from_ty);
                match to_ty.size() {
                    8 => self.emit(&format!("    movq %rax, {}(%rbp)", dst_offset)),
                    4 => self.emit(&format!("    movl %eax, {}(%rbp)", dst_offset)),
                    2 => self.emit(&format!("    movw %ax, {}(%rbp)", dst_offset)),
                    1 => self.emit(&format!("    movb %al, {}(%rbp)", dst_offset)),
                    _ => {}
                }
            }
            Instruction::BinOp {
                dst,
                op,
                lhs,
                rhs,
                ty,
            } => {
                let dst_offset = self.var_offsets[dst];
                let operand_ty = self.binop_operand_ty(op, lhs, rhs, ty);
                let result_ty = self
                    .var_types
                    .get(dst)
                    .cloned()
                    .unwrap_or_else(|| ty.clone());
                if operand_ty == Type::F64 {
                    self.generate_float_binop(dst_offset, op, lhs, rhs, &result_ty);
                    return;
                }

                // Whether the operand type is signed drives division, shift and
                // comparison instruction selection. `bool`/`char` are treated as
                // unsigned magnitudes.
                let signed = operand_ty.is_signed();

                self.load_value(lhs, "%rax", &operand_ty);
                self.load_value(rhs, "%rcx", &operand_ty);

                match op {
                    IrBinOp::Add if operand_ty.is_integer() => {
                        self.emit("    addq %rcx, %rax");
                    }
                    IrBinOp::Sub if operand_ty.is_integer() => {
                        self.emit("    subq %rcx, %rax");
                    }
                    IrBinOp::Mul if operand_ty.is_integer() => {
                        self.emit("    imulq %rcx, %rax");
                    }
                    IrBinOp::Div if operand_ty.is_integer() => {
                        if signed {
                            self.emit("    cqo");
                            self.emit("    idivq %rcx");
                        } else {
                            // Unsigned division zero-extends the dividend into
                            // %rdx and uses `div`.
                            self.emit("    xorq %rdx, %rdx");
                            self.emit("    divq %rcx");
                        }
                    }
                    IrBinOp::Mod if operand_ty.is_integer() => {
                        if signed {
                            self.emit("    cqo");
                            self.emit("    idivq %rcx");
                        } else {
                            self.emit("    xorq %rdx, %rdx");
                            self.emit("    divq %rcx");
                        }
                        self.emit("    movq %rdx, %rax");
                    }
                    // Bitwise operators work on every integer (and bool) width;
                    // the low bits are identical regardless of register width,
                    // so a single 64-bit form is correct.
                    IrBinOp::BitAnd | IrBinOp::And => {
                        self.emit("    andq %rcx, %rax");
                    }
                    IrBinOp::BitOr | IrBinOp::Or => {
                        self.emit("    orq %rcx, %rax");
                    }
                    IrBinOp::BitXor => {
                        self.emit("    xorq %rcx, %rax");
                    }
                    // Shifts take the count in %cl (the low byte of %rcx, where
                    // the rhs already lives). Left shift is the same for signed
                    // and unsigned; right shift is arithmetic (`sar`) for signed
                    // operands and logical (`shr`) for unsigned.
                    IrBinOp::Shl => {
                        self.emit("    shlq %cl, %rax");
                    }
                    IrBinOp::Shr => {
                        if signed {
                            self.emit("    sarq %cl, %rax");
                        } else {
                            self.emit("    shrq %cl, %rax");
                        }
                    }
                    IrBinOp::Eq => {
                        self.emit("    cmpq %rcx, %rax");
                        self.emit("    sete %al");
                        self.emit("    movzbq %al, %rax");
                    }
                    IrBinOp::Ne => {
                        self.emit("    cmpq %rcx, %rax");
                        self.emit("    setne %al");
                        self.emit("    movzbq %al, %rax");
                    }
                    // Relational comparisons: signed types use signed condition
                    // codes (`setl/setle/setg/setge`); unsigned types use the
                    // unsigned codes (`setb/setbe/seta/setae`). Previously the
                    // unsigned arms emitted *nothing*, silently dropping the
                    // comparison.
                    IrBinOp::Lt => {
                        self.emit("    cmpq %rcx, %rax");
                        self.emit(if signed {
                            "    setl %al"
                        } else {
                            "    setb %al"
                        });
                        self.emit("    movzbq %al, %rax");
                    }
                    IrBinOp::Le => {
                        self.emit("    cmpq %rcx, %rax");
                        self.emit(if signed {
                            "    setle %al"
                        } else {
                            "    setbe %al"
                        });
                        self.emit("    movzbq %al, %rax");
                    }
                    IrBinOp::Gt => {
                        self.emit("    cmpq %rcx, %rax");
                        self.emit(if signed {
                            "    setg %al"
                        } else {
                            "    seta %al"
                        });
                        self.emit("    movzbq %al, %rax");
                    }
                    IrBinOp::Ge => {
                        self.emit("    cmpq %rcx, %rax");
                        self.emit(if signed {
                            "    setge %al"
                        } else {
                            "    setae %al"
                        });
                        self.emit("    movzbq %al, %rax");
                    }
                    _ => {}
                }

                self.store_gpr_value("%rax", dst_offset, &result_ty);
            }
            Instruction::UnOp { dst, op, src, ty } => {
                let dst_offset = self.var_offsets[dst];
                if *ty == Type::F64 {
                    self.load_value(src, "%xmm0", ty);
                    match op {
                        IrUnOp::Neg => {
                            self.emit("    pxor %xmm1, %xmm1");
                            self.emit("    subsd %xmm0, %xmm1");
                            self.emit("    movapd %xmm1, %xmm0");
                        }
                        // Logical/bitwise complement are not defined on f64 and
                        // are rejected by validation/typechecking before codegen.
                        IrUnOp::Not | IrUnOp::BitNot => {}
                    }
                    self.store_xmm_value("%xmm0", dst_offset);
                    return;
                }

                self.load_value(src, "%rax", ty);

                match op {
                    IrUnOp::Neg => {
                        self.emit("    negq %rax");
                    }
                    // Logical not on a 0/1 bool: flip the low bit.
                    IrUnOp::Not => {
                        self.emit("    xorq $1, %rax");
                    }
                    // Bitwise complement (one's complement) on an integer.
                    IrUnOp::BitNot => {
                        self.emit("    notq %rax");
                    }
                }

                self.store_gpr_value("%rax", dst_offset, ty);
            }
            Instruction::Call {
                dst,
                func,
                args,
                ty,
            } => {
                self.load_call_args(args);
                self.emit(&format!("    call {}", Self::mangle_name(func)));
                self.store_call_result(dst, ty);
            }
            Instruction::CallIndirect {
                dst,
                func,
                args,
                ty,
            } => {
                self.load_call_args(args);
                let func_ty = self
                    .value_type(func)
                    .unwrap_or_else(|| Type::Func(Vec::new(), Box::new(Type::Unit)));
                self.load_value(func, "%rax", &func_ty);
                self.emit("    call *%rax");
                self.store_call_result(dst, ty);
            }
            Instruction::Branch {
                cond,
                true_label,
                false_label,
            } => {
                self.load_value(cond, "%rax", &Type::Bool);
                self.emit("    testq %rax, %rax");
                self.emit(&format!("    jnz {}", self.block_label(true_label)));
                self.emit(&format!("    jmp {}", self.block_label(false_label)));
            }
            Instruction::Jump(label) => {
                self.emit(&format!("    jmp {}", self.block_label(label)));
            }
            // `let` binding / `set!`: store a value into a local's stack slot.
            // Only direct local-variable addresses (`Value::Var`) are supported;
            // the local's slot *is* the storage, so this is a slot write rather
            // than a pointer dereference.
            Instruction::Store { dst, src, ty } => {
                let dst_var = match dst {
                    Value::Var(v) => *v,
                    // Validation rejects non-Var store addresses.
                    _ => return,
                };
                let dst_offset = self.var_offsets[&dst_var];
                if *ty == Type::F64 {
                    self.load_value(src, "%xmm0", ty);
                    self.store_xmm_value("%xmm0", dst_offset);
                    return;
                }

                match src {
                    Value::Var(_) => {
                        // Round-trip through a register sized to the value.
                        match ty.size() {
                            8 => {
                                self.load_value(src, "%rax", ty);
                                self.emit(&format!("    movq %rax, {}(%rbp)", dst_offset));
                            }
                            4 => {
                                self.load_value(src, "%rax", ty);
                                self.emit(&format!("    movl %eax, {}(%rbp)", dst_offset));
                            }
                            2 => {
                                self.load_value(src, "%rax", ty);
                                self.emit(&format!("    movw %ax, {}(%rbp)", dst_offset));
                            }
                            1 => {
                                self.load_value(src, "%rax", ty);
                                self.emit(&format!("    movb %al, {}(%rbp)", dst_offset));
                            }
                            _ => {}
                        }
                    }
                    Value::ConstI64(n) => {
                        self.emit(&format!("    movq ${}, {}(%rbp)", n, dst_offset));
                    }
                    Value::ConstI32(n) => {
                        self.emit(&format!("    movl ${}, {}(%rbp)", n, dst_offset));
                    }
                    Value::ConstI8(n) => {
                        self.emit(&format!("    movb ${}, {}(%rbp)", n, dst_offset));
                    }
                    Value::ConstBool(b) => {
                        let n = if *b { 1 } else { 0 };
                        self.emit(&format!("    movb ${}, {}(%rbp)", n, dst_offset));
                    }
                    _ => {}
                }
            }
            // Read a local's stack slot into the destination's slot.
            Instruction::Load { dst, src, ty } => {
                let dst_offset = self.var_offsets[dst];
                if *ty == Type::F64 {
                    self.load_value(src, "%xmm0", ty);
                    self.store_xmm_value("%xmm0", dst_offset);
                    return;
                }

                match ty.size() {
                    8 => {
                        self.load_value(src, "%rax", ty);
                        self.emit(&format!("    movq %rax, {}(%rbp)", dst_offset));
                    }
                    4 => {
                        self.load_value(src, "%rax", ty);
                        self.emit(&format!("    movl %eax, {}(%rbp)", dst_offset));
                    }
                    2 => {
                        self.load_value(src, "%rax", ty);
                        self.emit(&format!("    movw %ax, {}(%rbp)", dst_offset));
                    }
                    1 => {
                        self.load_value(src, "%rax", ty);
                        self.emit(&format!("    movb %al, {}(%rbp)", dst_offset));
                    }
                    _ => {}
                }
            }
            Instruction::Return(val) => {
                if let Some(v) = val {
                    let ret_ty = self.return_ty.clone();
                    if ret_ty == Type::F64 {
                        self.load_value(v, "%xmm0", &ret_ty);
                    } else {
                        self.load_value(v, "%rax", &ret_ty);
                    }
                }
                // Epilogue
                self.emit("    mov %rbp, %rsp");
                self.emit("    pop %rbp");
                self.emit("    ret");
            }
            _ => {
                // TODO: implement remaining instructions
                self.emit(&format!("    # TODO: {:?}", instr));
            }
        }
    }

    fn load_call_args(&mut self, args: &[Value]) {
        let param_regs = ["%rdi", "%rsi", "%rdx", "%rcx", "%r8", "%r9"];
        let xmm_regs = [
            "%xmm0", "%xmm1", "%xmm2", "%xmm3", "%xmm4", "%xmm5", "%xmm6", "%xmm7",
        ];
        let mut int_arg = 0;
        let mut float_arg = 0;
        for arg in args {
            let arg_ty = self.value_type(arg).unwrap_or(Type::I64);
            if arg_ty == Type::F64 {
                if float_arg < xmm_regs.len() {
                    self.load_value(arg, xmm_regs[float_arg], &Type::F64);
                }
                float_arg += 1;
            } else {
                if int_arg < param_regs.len() {
                    self.load_value(arg, param_regs[int_arg], &arg_ty);
                }
                int_arg += 1;
            }
        }
    }

    fn store_call_result(&mut self, dst: &Option<VarId>, ty: &Type) {
        if let Some(dst_var) = dst {
            let dst_offset = self.var_offsets[dst_var];
            if *ty == Type::F64 {
                self.store_xmm_value("%xmm0", dst_offset);
            } else {
                self.store_gpr_value("%rax", dst_offset, ty);
            }
        }
    }

    fn load_value(&mut self, val: &Value, reg: &str, ty: &Type) {
        if *ty == Type::F64 {
            self.load_float_value(val, reg);
            return;
        }

        match val {
            Value::ConstI64(n) => {
                self.emit(&format!("    movq ${}, {}", n, reg));
            }
            Value::ConstI32(n) => {
                self.emit(&format!("    movl ${}, {}", n, Self::gpr32(reg)));
            }
            Value::ConstI8(n) => {
                self.emit(&format!("    movq ${}, {}", n, reg));
            }
            Value::ConstBool(b) => {
                let n = if *b { 1 } else { 0 };
                self.emit(&format!("    movq ${}, {}", n, reg));
            }
            Value::Var(v) => {
                let offset = self.var_offsets[v];
                // Scalar slots are 8 bytes wide. Load the value into the full
                // 64-bit register, extending narrower types so the upper bits
                // are well-defined for the subsequent op/compare. Signed types
                // sign-extend (`movs..`); unsigned types (and bool/char)
                // zero-extend (`movz..`) so signed/unsigned comparisons and
                // arithmetic see correctly-extended operands.
                let signed = ty.is_signed();
                match ty.size() {
                    8 => self.emit(&format!("    movq {}(%rbp), {}", offset, reg)),
                    4 if signed => self.emit(&format!("    movslq {}(%rbp), {}", offset, reg)),
                    // `movl` into the 32-bit sub-register zero-extends into the
                    // full 64-bit register on x86_64.
                    4 => self.emit(&format!("    movl {}(%rbp), {}", offset, Self::gpr32(reg))),
                    2 if signed => self.emit(&format!("    movswq {}(%rbp), {}", offset, reg)),
                    2 => self.emit(&format!("    movzwq {}(%rbp), {}", offset, reg)),
                    1 if signed => self.emit(&format!("    movsbq {}(%rbp), {}", offset, reg)),
                    1 => self.emit(&format!("    movzbq {}(%rbp), {}", offset, reg)),
                    _ => {}
                }
            }
            _ => {}
        }
    }

    fn load_float_value(&mut self, val: &Value, reg: &str) {
        match val {
            Value::ConstF64(n) => {
                self.emit(&format!("    movabsq ${:#x}, %rax", n.to_bits()));
                self.emit(&format!("    movq %rax, {}", reg));
            }
            Value::Var(v) => {
                let offset = self.var_offsets[v];
                self.emit(&format!("    movsd {}(%rbp), {}", offset, reg));
            }
            _ => {}
        }
    }

    fn store_gpr_value(&mut self, reg: &str, offset: i32, ty: &Type) {
        match ty.size() {
            8 => self.emit(&format!("    movq {}, {}(%rbp)", reg, offset)),
            4 => self.emit(&format!("    movl {}, {}(%rbp)", Self::gpr32(reg), offset)),
            2 => self.emit(&format!("    movw {}, {}(%rbp)", Self::gpr16(reg), offset)),
            1 => self.emit(&format!("    movb {}, {}(%rbp)", Self::gpr8(reg), offset)),
            _ => {}
        }
    }

    fn store_xmm_value(&mut self, reg: &str, offset: i32) {
        self.emit(&format!("    movsd {}, {}(%rbp)", reg, offset));
    }

    fn generate_float_binop(
        &mut self,
        dst_offset: i32,
        op: &IrBinOp,
        lhs: &Value,
        rhs: &Value,
        result_ty: &Type,
    ) {
        self.load_value(lhs, "%xmm0", &Type::F64);
        self.load_value(rhs, "%xmm1", &Type::F64);

        match op {
            IrBinOp::Add => self.emit("    addsd %xmm1, %xmm0"),
            IrBinOp::Sub => self.emit("    subsd %xmm1, %xmm0"),
            IrBinOp::Mul => self.emit("    mulsd %xmm1, %xmm0"),
            IrBinOp::Div => self.emit("    divsd %xmm1, %xmm0"),
            IrBinOp::Eq | IrBinOp::Ne | IrBinOp::Lt | IrBinOp::Le | IrBinOp::Gt | IrBinOp::Ge => {
                self.emit("    ucomisd %xmm1, %xmm0");
                let setcc = match op {
                    IrBinOp::Eq => "sete",
                    IrBinOp::Ne => "setne",
                    IrBinOp::Lt => "setb",
                    IrBinOp::Le => "setbe",
                    IrBinOp::Gt => "seta",
                    IrBinOp::Ge => "setae",
                    _ => unreachable!(),
                };
                self.emit(&format!("    {} %al", setcc));
                self.emit("    movzbq %al, %rax");
                self.store_gpr_value("%rax", dst_offset, result_ty);
                return;
            }
            // Integer-only operators (modulo, logical and bitwise/shift) are
            // not defined on f64 and are rejected by validation before codegen.
            IrBinOp::Mod
            | IrBinOp::And
            | IrBinOp::Or
            | IrBinOp::BitAnd
            | IrBinOp::BitOr
            | IrBinOp::BitXor
            | IrBinOp::Shl
            | IrBinOp::Shr => {}
        }

        self.store_xmm_value("%xmm0", dst_offset);
    }

    fn binop_operand_ty(&self, op: &IrBinOp, lhs: &Value, rhs: &Value, result_ty: &Type) -> Type {
        match op {
            IrBinOp::Eq | IrBinOp::Ne | IrBinOp::Lt | IrBinOp::Le | IrBinOp::Gt | IrBinOp::Ge => {
                self.value_type(lhs)
                    .or_else(|| self.value_type(rhs))
                    .unwrap_or_else(|| result_ty.clone())
            }
            _ => result_ty.clone(),
        }
    }

    fn value_type(&self, val: &Value) -> Option<Type> {
        match val {
            Value::ConstI64(_) => Some(Type::I64),
            Value::ConstI32(_) => Some(Type::I32),
            Value::ConstI8(_) => Some(Type::I8),
            Value::ConstF64(_) => Some(Type::F64),
            Value::ConstBool(_) => Some(Type::Bool),
            Value::ConstUnit => Some(Type::Unit),
            Value::Var(v) => self.var_types.get(v).cloned(),
            Value::Global(_) => None,
        }
    }

    /// Map a 64-bit register name (e.g. `%rax`) to its 32-bit sub-register
    /// (`%eax`). A `movl` into the 32-bit form zero-extends into the full
    /// 64-bit register on x86_64.
    fn gpr32(reg: &str) -> &str {
        match reg {
            "%rax" => "%eax",
            "%rcx" => "%ecx",
            "%rdx" => "%edx",
            "%rbx" => "%ebx",
            "%rdi" => "%edi",
            "%rsi" => "%esi",
            "%r8" => "%r8d",
            "%r9" => "%r9d",
            "%r10" => "%r10d",
            "%r11" => "%r11d",
            _ => reg,
        }
    }

    /// Map a 64-bit register name to its 16-bit sub-register (`%rax` -> `%ax`).
    fn gpr16(reg: &str) -> &str {
        match reg {
            "%rax" => "%ax",
            "%rcx" => "%cx",
            "%rdx" => "%dx",
            "%rbx" => "%bx",
            "%rsi" => "%si",
            "%rdi" => "%di",
            "%r8" => "%r8w",
            "%r9" => "%r9w",
            "%r10" => "%r10w",
            "%r11" => "%r11w",
            _ => reg,
        }
    }

    /// Map a 64-bit register name to its 8-bit (low byte) sub-register
    /// (`%rax`->`%al`).
    fn gpr8(reg: &str) -> &str {
        match reg {
            "%rax" => "%al",
            "%rcx" => "%cl",
            "%rdx" => "%dl",
            "%rbx" => "%bl",
            "%rdi" => "%dil",
            "%rsi" => "%sil",
            "%r8" => "%r8b",
            "%r9" => "%r9b",
            "%r10" => "%r10b",
            "%r11" => "%r11b",
            _ => reg,
        }
    }

    fn emit(&mut self, line: &str) {
        self.output.push_str(line);
        self.output.push('\n');
    }

    fn mangle_name(name: &str) -> String {
        // Simple name mangling
        if name == "main" {
            "main".into()
        } else {
            format!("_tl_{}", name.replace('-', "_"))
        }
    }

    fn fresh_label(&mut self, prefix: &str) -> String {
        let label = format!("{}.{}", prefix, self.label_counter);
        self.label_counter += 1;
        label
    }

    /// Qualify a bare IR block label (e.g. `then.0`) with the current function's
    /// mangled symbol so it matches the emitted block label `{fn}.{block}:`.
    fn block_label(&self, label: &str) -> String {
        format!("{}.{}", self.current_fn, label)
    }
}

/// Generate x86_64 assembly for a (lowered + optimized) IR program.
///
/// Returns `Err` with a clear, user-facing message if the program uses
/// constructs the backend cannot yet faithfully compile, rather than emitting
/// silently incorrect assembly.
pub fn generate_assembly(program: &Program) -> Result<String, String> {
    validate_program(program)?;
    let mut backend = X86_64Backend::new();
    Ok(backend.generate(program))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ast;
    use crate::ir::*;
    use crate::lower::lower_program;
    use crate::optimizer::Optimizer;
    use crate::parser::parse;

    /// Compile source through the full pipeline (parse -> lower -> optimize ->
    /// codegen), returning generated assembly text.
    fn compile_ok(source: &str) -> String {
        let prog = parse(source).expect("parse failed");
        let mut ir = lower_program(&prog);
        Optimizer::optimize(&mut ir);
        generate_assembly(&ir).expect("backend should accept this program")
    }

    /// Compile source expecting the backend to reject it.
    fn compile_err(source: &str) -> String {
        let prog = parse(source).expect("parse failed");
        let mut ir = lower_program(&prog);
        Optimizer::optimize(&mut ir);
        generate_assembly(&ir).expect_err("backend should reject this program")
    }

    #[test]
    fn test_backend_simple_main() {
        let program = Program {
            functions: vec![Function {
                name: "main".to_string(),
                params: vec![],
                ret: Type::I64,
                locals: vec![],
                blocks: vec![BasicBlock {
                    label: "entry".to_string(),
                    instructions: vec![Instruction::Return(Some(Value::ConstI64(3)))],
                }],
                entry: "entry".to_string(),
            }],
            globals: vec![],
            externs: vec![],
        };
        let asm = generate_assembly(&program).expect("simple main should compile");
        assert!(asm.contains("    .globl _start"));
        assert!(asm.contains("main:"));
        assert!(asm.contains("movq $3, %rax"));
        assert!(asm.contains("ret"));
        assert!(asm.contains("_start:"));
        assert!(asm.contains("    call main"));
        assert!(asm.contains("    movq $60, %rax"));
    }

    #[test]
    fn test_compile_constant_main() {
        // (+ 1 2) folds to a constant; backend should emit the literal in %rax.
        let asm = compile_ok("(define (main) : i64 (+ 1 2))");
        assert!(asm.contains("    .globl main"));
        assert!(asm.contains("    .globl _start"));
        assert!(asm.contains("main:"));
        assert!(asm.contains("movq $3, %rax"));
    }

    #[test]
    fn test_compile_add_function() {
        // Parameters are loaded from registers into stack slots, added, returned.
        let asm = compile_ok("(define (add [a : i64] [b : i64]) : i64 (+ a b))");
        // Mangled non-main name.
        assert!(asm.contains("_tl_add:"), "asm:\n{}", asm);
        // Prologue moves the two integer params from rdi/rsi to stack slots
        // (now emitted with an explicit size suffix).
        assert!(asm.contains("movq %rdi,"), "asm:\n{}", asm);
        assert!(asm.contains("movq %rsi,"), "asm:\n{}", asm);
        // The actual addition.
        assert!(asm.contains("addq %rcx, %rax"), "asm:\n{}", asm);
        // Block labels are emitted as valid (colon-terminated) GAS labels.
        assert!(asm.contains("_tl_add.entry:"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_subtraction() {
        let asm = compile_ok("(define (sub [a : i64] [b : i64]) : i64 (- a b))");
        assert!(asm.contains("subq %rcx, %rax"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_direct_call_and_recursion() {
        // Direct calls (including the recursive shape without `if`) are supported:
        // arguments go into the SysV argument registers and a `call` is emitted.
        let asm = compile_ok(
            r#"
            (define (inc [x : i64]) : i64 (+ x 1))
            (define (twice [x : i64]) : i64 (inc (inc x)))
        "#,
        );
        assert!(asm.contains("_tl_inc:"), "asm:\n{}", asm);
        assert!(asm.contains("_tl_twice:"), "asm:\n{}", asm);
        assert!(asm.contains("call _tl_inc"), "asm:\n{}", asm);
        // Argument register load for the call.
        assert!(asm.contains("%rdi"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_indirect_call_through_function_pointer_param() {
        let program = Program {
            functions: vec![Function {
                name: "apply1".into(),
                params: vec![
                    (0, Type::Func(vec![Type::I64], Box::new(Type::I64))),
                    (1, Type::I64),
                ],
                ret: Type::I64,
                locals: vec![(2, Type::I64)],
                blocks: vec![BasicBlock {
                    label: "entry".into(),
                    instructions: vec![
                        Instruction::CallIndirect {
                            dst: Some(2),
                            func: Value::Var(0),
                            args: vec![Value::Var(1)],
                            ty: Type::I64,
                        },
                        Instruction::Return(Some(Value::Var(2))),
                    ],
                }],
                entry: "entry".into(),
            }],
            globals: vec![],
            externs: vec![],
        };
        let asm = generate_assembly(&program).expect("function-pointer call should compile");
        assert!(asm.contains("_tl_apply1:"), "asm:\n{}", asm);
        assert!(asm.contains("    movq -16(%rbp), %rdi"), "asm:\n{}", asm);
        assert!(asm.contains("    movq -8(%rbp), %rax"), "asm:\n{}", asm);
        assert!(asm.contains("    call *%rax"), "asm:\n{}", asm);
        assert!(!asm.contains("# TODO"), "unhandled instruction:\n{}", asm);
    }

    #[test]
    fn test_reject_indirect_call_through_non_function_value() {
        let err = generate_assembly(&Program {
            functions: vec![Function {
                name: "bad".into(),
                params: vec![(0, Type::I64)],
                ret: Type::I64,
                locals: vec![(1, Type::I64)],
                blocks: vec![BasicBlock {
                    label: "entry".into(),
                    instructions: vec![Instruction::CallIndirect {
                        dst: Some(1),
                        func: Value::Var(0),
                        args: vec![],
                        ty: Type::I64,
                    }],
                }],
                entry: "entry".into(),
            }],
            globals: vec![],
            externs: vec![],
        })
        .expect_err("non-function indirect call target should be rejected");
        assert!(
            err.contains("indirect call through a non-function value"),
            "err: {}",
            err
        );
    }

    #[test]
    fn test_compile_synthesizes_main_when_absent() {
        // A program with no `main` gets a trivial `main` so the entry symbol exists.
        let asm = compile_ok("(define (helper [x : i64]) : i64 (+ x 1))");
        assert!(asm.contains("main:"), "asm:\n{}", asm);
        assert!(asm.contains("xor %eax, %eax"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_comparison() {
        let asm = compile_ok("(define (lt [a : i64] [b : i64]) : bool (< a b))");
        assert!(asm.contains("cmpq %rcx, %rax"), "asm:\n{}", asm);
        assert!(asm.contains("setl %al"), "asm:\n{}", asm);
        assert!(asm.contains("movb %al,"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_float_constant_return() {
        let asm = compile_ok("(define (pi) : f64 3.14)");
        assert!(
            asm.contains("movabsq $0x40091eb851eb851f, %rax"),
            "asm:\n{}",
            asm
        );
        assert!(asm.contains("movq %rax, %xmm0"), "asm:\n{}", asm);
        assert!(asm.contains("ret"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_float_add_function() {
        let asm = compile_ok("(define (addf [a : f64] [b : f64]) : f64 (+ a b))");
        assert!(asm.contains("movsd %xmm0,"), "asm:\n{}", asm);
        assert!(asm.contains("movsd %xmm1,"), "asm:\n{}", asm);
        assert!(asm.contains("addsd %xmm1, %xmm0"), "asm:\n{}", asm);
        assert!(!asm.contains("addq %rcx, %rax"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_float_comparison() {
        let asm = compile_ok("(define (ltf [a : f64] [b : f64]) : bool (< a b))");
        assert!(asm.contains("ucomisd %xmm1, %xmm0"), "asm:\n{}", asm);
        assert!(asm.contains("setb %al"), "asm:\n{}", asm);
        assert!(asm.contains("movb %al,"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_float_negation() {
        let prog = ast::Program {
            decls: vec![ast::Decl::DefFn {
                name: "negf".into(),
                params: vec![("x".into(), Type::F64)],
                ret: Type::F64,
                body: ast::Expr::Unary {
                    op: ast::UnOp::Neg,
                    expr: Box::new(ast::Expr::Var("x".into())),
                },
            }],
        };
        let mut ir = lower_program(&prog);
        Optimizer::optimize(&mut ir);
        let asm = generate_assembly(&ir).expect("backend should accept f64 negation");
        assert!(asm.contains("pxor %xmm1, %xmm1"), "asm:\n{}", asm);
        assert!(asm.contains("subsd %xmm0, %xmm1"), "asm:\n{}", asm);
        assert!(asm.contains("movapd %xmm1, %xmm0"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_float_call_args_and_return() {
        let asm = compile_ok(
            r#"
            (define (half [x : f64]) : f64 (/ x 2.0))
            (define (main) : f64 (half 4.0))
        "#,
        );
        assert!(asm.contains("call _tl_half"), "asm:\n{}", asm);
        assert!(asm.contains("divsd %xmm1, %xmm0"), "asm:\n{}", asm);
        assert!(asm.contains("movq %rax, %xmm0"), "asm:\n{}", asm);
        assert!(asm.contains("movsd %xmm0,"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_mixed_integer_and_float_params_use_independent_abi_registers() {
        let asm = compile_ok("(define (second [n : i64] [x : f64]) : f64 x)");
        assert!(asm.contains("    movq %rdi, -8(%rbp)"), "asm:\n{}", asm);
        assert!(asm.contains("    movsd %xmm0, -16(%rbp)"), "asm:\n{}", asm);
        assert!(!asm.contains("    movsd %xmm1, -16(%rbp)"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_float_let_binding_uses_xmm_load_store() {
        let asm = compile_ok("(define (idlet [x : f64]) : f64 (let ([y : f64 x]) y))");
        assert!(asm.contains("movsd -8(%rbp), %xmm0"), "asm:\n{}", asm);
        assert!(asm.contains("movsd %xmm0, -16(%rbp)"), "asm:\n{}", asm);
        assert!(!asm.contains("movsd %rax"), "asm:\n{}", asm);
        assert!(!asm.contains("# TODO"), "unhandled instruction:\n{}", asm);
    }

    // ---- Graceful rejection of out-of-scope constructs -----------------

    // ---- Control flow: `if` / Phi (issue #36) --------------------------

    #[test]
    fn test_compile_if_expression() {
        // `if` lowers to a Branch into then/else blocks and a Phi in the merge
        // block. The backend now selects this: a conditional `jnz` to the then
        // label, an unconditional fall-through `jmp` to the else label, a
        // colon-terminated merge label, and a `mov` of each arm's value into
        // the phi's stack slot at the end of each predecessor.
        let asm = compile_ok("(define (max [a : i64] [b : i64]) : i64 (if (> a b) a b))");

        // Conditional branch selection against qualified block labels.
        assert!(asm.contains("testq %rax, %rax"), "asm:\n{}", asm);
        assert!(asm.contains("jnz _tl_max.then."), "asm:\n{}", asm);
        assert!(asm.contains("jmp _tl_max.else."), "asm:\n{}", asm);

        // The merge block is emitted as a real, colon-terminated GAS label, and
        // both arms jump to it. Find the actual merge label and assert it is
        // defined (followed by `:`) as well as targeted by the jumps.
        let merge_def = asm
            .lines()
            .find(|l| l.starts_with("_tl_max.merge.") && l.ends_with(':'));
        assert!(
            merge_def.is_some(),
            "merge label not defined; asm:\n{}",
            asm
        );
        let merge_jumps = asm.matches("jmp _tl_max.merge.").count();
        assert_eq!(
            merge_jumps, 2,
            "both arms should jump to merge; asm:\n{}",
            asm
        );

        // Phi elimination: each arm writes its value into the phi's stack slot.
        // The phi result is the function result, so the merge block returns it.
        assert!(asm.contains("(%rbp)"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_if_phi_slot_moves() {
        // Verify the phi result is materialized by stack-slot moves in the
        // predecessor blocks (not by a fall-through that reads an undefined
        // register). We expect a load of each arm's value into a register and a
        // store into a single stack slot, performed on both arms.
        let asm = compile_ok("(define (pick [a : i64] [b : i64]) : i64 (if (> a b) 100 200))");
        // The two constant arms move their literals into the phi slot. After
        // copy-propagation the constants reach the phi sources directly.
        assert!(asm.contains("$100"), "asm:\n{}", asm);
        assert!(asm.contains("$200"), "asm:\n{}", asm);
        // Branch + both merge jumps present.
        assert!(asm.contains("jnz _tl_pick.then."), "asm:\n{}", asm);
        assert_eq!(
            asm.matches("jmp _tl_pick.merge.").count(),
            2,
            "asm:\n{}",
            asm
        );
    }

    #[test]
    fn test_compile_recursive_factorial() {
        // A recursive function using `if` must emit real branching assembly
        // plus a recursive `call`. This exercises Branch/Phi/Call together.
        let asm = compile_ok(
            r#"
            (define (fact [n : i64]) : i64
              (if (<= n 1)
                1
                (* n (fact (- n 1)))))
        "#,
        );
        assert!(asm.contains("_tl_fact:"), "asm:\n{}", asm);
        // The condition comparison and branch.
        assert!(asm.contains("setle %al"), "asm:\n{}", asm);
        assert!(asm.contains("jnz _tl_fact.then."), "asm:\n{}", asm);
        assert!(asm.contains("jmp _tl_fact.else."), "asm:\n{}", asm);
        // Recursive call.
        assert!(asm.contains("call _tl_fact"), "asm:\n{}", asm);
        // Multiplication on the recursive arm.
        assert!(asm.contains("imulq %rcx, %rax"), "asm:\n{}", asm);
        // Both arms converge on the merge block.
        assert_eq!(
            asm.matches("jmp _tl_fact.merge.").count(),
            2,
            "asm:\n{}",
            asm
        );
    }

    // ---- Locals: `let` / `set!` (Alloc/Store/Load) (issue #36) ---------

    #[test]
    fn test_compile_let_binding() {
        // `(let ([y (+ x x)]) (+ y x))` allocates a slot for `y`, stores the
        // computed value into it, and later loads it. The backend now emits a
        // real store into y's slot rather than rejecting the program.
        let asm = compile_ok("(define (triple [x : i64]) : i64 (let ([y : i64 (+ x x)]) (+ y x)))");
        assert!(asm.contains("_tl_triple:"), "asm:\n{}", asm);
        // The `(+ x x)` addition feeding the binding.
        assert!(asm.contains("addq %rcx, %rax"), "asm:\n{}", asm);
        // A store into y's stack slot, then a later load/use from a slot.
        assert!(asm.contains("(%rbp)"), "asm:\n{}", asm);
        // No leftover TODO placeholder for Store/Load.
        assert!(!asm.contains("# TODO"), "unhandled instruction:\n{}", asm);
    }

    #[test]
    fn test_compile_set_mutation() {
        // `set!` lowers to a Store into the variable's existing slot. The
        // begin-sequence increments x twice, so two stores must be emitted.
        let asm = compile_ok(
            r#"
            (define (add2 [x : i64]) : i64
              (begin
                (set! x (+ x 1))
                (set! x (+ x 1))
                x))
        "#,
        );
        assert!(asm.contains("_tl_add2:"), "asm:\n{}", asm);
        // Two `(+ x 1)` additions.
        assert_eq!(asm.matches("addq %rcx, %rax").count(), 2, "asm:\n{}", asm);
        assert!(!asm.contains("# TODO"), "unhandled instruction:\n{}", asm);
    }

    #[test]
    fn test_compile_while_loop() {
        // `while` lowers to a header/body/exit block structure with a back-edge
        // jump from the body to the header. Verify the qualified labels and the
        // back-edge are emitted.
        let asm = compile_ok(
            r#"
            (define (countdown [n : i64]) : i64
              (let ([x : i64 n])
                (begin
                  (while (> x 0)
                    (set! x (- x 1)))
                  x)))
        "#,
        );
        assert!(asm.contains("_tl_countdown.while_header."), "asm:\n{}", asm);
        assert!(asm.contains("_tl_countdown.while_body."), "asm:\n{}", asm);
        assert!(asm.contains("_tl_countdown.while_exit."), "asm:\n{}", asm);
        // Header conditional branch into body / exit.
        assert!(
            asm.contains("jnz _tl_countdown.while_body."),
            "asm:\n{}",
            asm
        );
        // Back-edge from the body to the header.
        assert!(
            asm.contains("jmp _tl_countdown.while_header."),
            "asm:\n{}",
            asm
        );
        assert!(!asm.contains("# TODO"), "unhandled instruction:\n{}", asm);
    }

    #[test]
    fn test_reject_empty_program() {
        let err = generate_assembly(&Program {
            functions: vec![],
            globals: vec![],
            externs: vec![],
        })
        .expect_err("empty program should be rejected");
        assert!(err.contains("no functions"), "err: {}", err);
    }

    // ---- Bitwise / shift / cast / unsigned codegen (issue #46) ---------

    #[test]
    fn test_compile_bit_and() {
        let asm = compile_ok("(define (f [a : i64] [b : i64]) : i64 (bit-and a b))");
        assert!(asm.contains("andq %rcx, %rax"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_bit_or() {
        let asm = compile_ok("(define (f [a : i64] [b : i64]) : i64 (bit-or a b))");
        assert!(asm.contains("orq %rcx, %rax"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_bit_xor_emits_xor_not_or() {
        // Miscompile bug 1: bit-xor used to emit `orq`. It must now emit `xorq`.
        let asm = compile_ok("(define (f [a : i64] [b : i64]) : i64 (bit-xor a b))");
        assert!(asm.contains("xorq %rcx, %rax"), "asm:\n{}", asm);
        // The only `orq` allowed would be a bitwise-or, which this program has
        // none of, so assert no stray `orq` instruction slipped through. Match
        // the emitted-line form (`    orq `) to avoid matching the substring
        // inside `xorq`.
        assert!(
            !asm.contains("    orq "),
            "bit-xor must not emit orq; asm:\n{}",
            asm
        );
    }

    #[test]
    fn test_compile_shl_emits_shift_not_add() {
        // Miscompile bug 2: shl used to emit `addq`. It must now emit a real
        // shift through %cl.
        let asm = compile_ok("(define (f [a : i64] [b : i64]) : i64 (shl a b))");
        assert!(asm.contains("shlq %cl, %rax"), "asm:\n{}", asm);
        assert!(
            !asm.contains("addq %rcx, %rax"),
            "shl must not emit addq; asm:\n{}",
            asm
        );
    }

    #[test]
    fn test_compile_shr_signed_is_arithmetic() {
        // Signed right shift must be arithmetic (`sarq`).
        let asm = compile_ok("(define (f [a : i64] [b : i64]) : i64 (shr a b))");
        assert!(asm.contains("sarq %cl, %rax"), "asm:\n{}", asm);
        assert!(
            !asm.contains("shrq %cl, %rax"),
            "signed shr must be arithmetic; asm:\n{}",
            asm
        );
    }

    #[test]
    fn test_compile_shr_unsigned_is_logical() {
        // Unsigned right shift must be logical (`shrq`).
        let asm = compile_ok("(define (f [a : u64] [b : u64]) : u64 (shr a b))");
        assert!(asm.contains("shrq %cl, %rax"), "asm:\n{}", asm);
        assert!(
            !asm.contains("sarq %cl, %rax"),
            "unsigned shr must be logical; asm:\n{}",
            asm
        );
    }

    #[test]
    fn test_compile_signed_comparison_uses_signed_codes() {
        // i64 `<` keeps signed condition codes.
        let asm = compile_ok("(define (f [a : i64] [b : i64]) : bool (< a b))");
        assert!(asm.contains("setl %al"), "asm:\n{}", asm);
        assert!(!asm.contains("setb %al"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_unsigned_less_emits_setb() {
        // Previously the `is_signed()` gate dropped unsigned comparisons
        // entirely (no `set*` emitted). They must now emit unsigned codes.
        let asm = compile_ok("(define (f [a : u64] [b : u64]) : bool (< a b))");
        assert!(asm.contains("setb %al"), "asm:\n{}", asm);
        assert!(!asm.contains("setl %al"), "asm:\n{}", asm);
    }

    #[test]
    fn test_compile_unsigned_relations_emit_unsigned_codes() {
        let asm_le = compile_ok("(define (f [a : u32] [b : u32]) : bool (<= a b))");
        assert!(asm_le.contains("setbe %al"), "asm:\n{}", asm_le);
        let asm_gt = compile_ok("(define (f [a : u32] [b : u32]) : bool (> a b))");
        assert!(asm_gt.contains("seta %al"), "asm:\n{}", asm_gt);
        let asm_ge = compile_ok("(define (f [a : u32] [b : u32]) : bool (>= a b))");
        assert!(asm_ge.contains("setae %al"), "asm:\n{}", asm_ge);
    }

    #[test]
    fn test_compile_cast_truncate_to_i8() {
        // Narrowing cast i64 -> i8: load source then store only the low byte.
        let asm = compile_ok("(define (f [x : i64]) : i8 (cast x : i8))");
        assert!(
            asm.contains("movb %al,"),
            "truncation expected; asm:\n{}",
            asm
        );
    }

    #[test]
    fn test_compile_cast_widen_i8_to_i64_sign_extends() {
        // Widening cast i8 -> i64 must sign-extend the source.
        let asm = compile_ok("(define (f [x : i8]) : i64 (cast x : i64))");
        assert!(
            asm.contains("movsbq"),
            "sign-extension expected; asm:\n{}",
            asm
        );
    }

    #[test]
    fn test_compile_cast_widen_u8_to_i64_zero_extends() {
        // Widening cast u8 -> i64 must zero-extend the source.
        let asm = compile_ok("(define (f [x : u8]) : i64 (cast x : i64))");
        assert!(
            asm.contains("movzbq"),
            "zero-extension expected; asm:\n{}",
            asm
        );
    }

    #[test]
    fn test_compile_bit_not_emits_notq() {
        // bit-not (one's complement). Unary ops are not parsed from text yet,
        // so drive the backend from hand-built IR.
        let program = Program {
            functions: vec![Function {
                name: "f".into(),
                params: vec![(0, Type::I64)],
                ret: Type::I64,
                locals: vec![(1, Type::I64)],
                blocks: vec![BasicBlock {
                    label: "entry".into(),
                    instructions: vec![
                        Instruction::Alloc {
                            var: 0,
                            ty: Type::I64,
                        },
                        Instruction::UnOp {
                            dst: 1,
                            op: UnOp::BitNot,
                            src: Value::Var(0),
                            ty: Type::I64,
                        },
                        Instruction::Return(Some(Value::Var(1))),
                    ],
                }],
                entry: "entry".into(),
            }],
            globals: vec![],
            externs: vec![],
        };
        let asm = generate_assembly(&program).expect("bit-not should compile");
        assert!(asm.contains("notq %rax"), "asm:\n{}", asm);
    }
}
