#![allow(dead_code)]

use crate::ir::{
    BasicBlock, BinOp as IrBinOp, Function, Instruction, Label, Program, UnOp as IrUnOp, Value,
    VarId,
};
use crate::types::Type;
use std::collections::HashSet;

/// x86_64 assembly code generator
/// Target: Linux, System V AMD64 ABI
pub struct X86_64Backend {
    output: String,
    label_counter: u32,
    stack_size: i32,
    var_offsets: std::collections::HashMap<VarId, i32>,
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
/// against a local's stack slot) over integer/bool/char scalars.
///
/// Constructs that are lowered but NOT yet selected to assembly (floats #37,
/// indirect calls #38, address/GEP pointer arithmetic and `Global` operands)
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
    let unsupported = |what: &str| {
        Err(format!(
            "backend: function '{}' uses an unsupported construct ({}). \
             The x86_64 backend currently supports scalar arithmetic, comparisons, \
             unary/binary operators, direct function calls, recursion, control flow \
             (if/while) and scalar let/set! locals. Floats (#37), indirect calls \
             (#38), tuples, arrays, lambdas and strings are not yet wired (see #13).",
            func.name, what
        ))
    };

    for block in &func.blocks {
        for instr in &block.instructions {
            match instr {
                // Fully supported scalar instructions.
                Instruction::BinOp { lhs, rhs, .. } => {
                    check_operand(lhs).map_err(|w| unsupported_value(&func.name, &w))?;
                    check_operand(rhs).map_err(|w| unsupported_value(&func.name, &w))?;
                }
                Instruction::UnOp { src, .. } => {
                    check_operand(src).map_err(|w| unsupported_value(&func.name, &w))?;
                }
                Instruction::Mov { src, .. } => {
                    check_operand(src).map_err(|w| unsupported_value(&func.name, &w))?;
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
                Instruction::AddrOf { .. } => return unsupported("address-of"),
                Instruction::Gep { .. } => return unsupported("get-element-pointer"),
                Instruction::CallIndirect { .. } => return unsupported("indirect call"),
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
        | Value::ConstBool(_)
        | Value::Var(_) => Ok(()),
        Value::ConstF64(_) => Err("floating-point constant".into()),
        Value::ConstUnit => Err("unit value".into()),
        Value::Global(name) => Err(format!("global/unresolved reference '{}'", name)),
    }
}

fn unsupported_value(func: &str, what: &str) -> String {
    format!(
        "backend: function '{}' uses an unsupported operand ({}). \
         The x86_64 backend currently supports integer, bool and char scalars only.",
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
            var_offsets: std::collections::HashMap::new(),
            param_vars: HashSet::new(),
            current_fn: String::new(),
        }
    }

    pub fn generate(&mut self, program: &Program) -> String {
        self.emit("    .text");
        self.emit("    .globl main");
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
        self.param_vars = func.params.iter().map(|(v, _)| *v).collect();

        // Allocate space for parameters (so their Alloc no-ops have a slot) and
        // locals.
        for (var, ty) in func.params.iter().chain(func.locals.iter()) {
            let size = ty.size() as i32;
            let align = ty.align() as i32;
            self.stack_size = (self.stack_size + align - 1) & !(align - 1);
            self.stack_size += size;
            self.var_offsets.insert(*var, -self.stack_size);
        }

        // Align stack to 16 bytes
        self.stack_size = (self.stack_size + 15) & !15;

        if self.stack_size > 0 {
            self.emit(&format!("    sub ${}, %rsp", self.stack_size));
        }

        // Move parameters to stack slots
        let param_regs = ["%rdi", "%rsi", "%rdx", "%rcx", "%r8", "%r9"];
        for (i, (var, ty)) in func.params.iter().enumerate() {
            if i < 6 {
                let offset = self.var_offsets[var];
                match ty {
                    Type::I64 | Type::U64 | Type::Func(_, _) => {
                        self.emit(&format!("    mov {}, {}(%rbp)", param_regs[i], offset));
                    }
                    Type::I32 | Type::U32 => {
                        self.emit(&format!(
                            "    movl {}d, {}(%rbp)",
                            &param_regs[i][1..],
                            offset
                        ));
                    }
                    Type::I8 | Type::U8 | Type::Bool => {
                        self.emit(&format!(
                            "    movb {}b, {}(%rbp)",
                            &param_regs[i][1..],
                            offset
                        ));
                    }
                    Type::F64 => {
                        let xmm_reg = [
                            "%xmm0", "%xmm1", "%xmm2", "%xmm3", "%xmm4", "%xmm5", "%xmm6", "%xmm7",
                        ];
                        if i < xmm_reg.len() {
                            self.emit(&format!("    movsd {}, {}(%rbp)", xmm_reg[i], offset));
                        }
                    }
                    _ => {}
                }
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
            Instruction::BinOp {
                dst,
                op,
                lhs,
                rhs,
                ty,
            } => {
                let dst_offset = self.var_offsets[dst];
                self.load_value(lhs, "%rax", ty);
                self.load_value(rhs, "%rcx", ty);

                match (op, ty) {
                    (IrBinOp::Add, t) if t.is_integer() => {
                        self.emit("    addq %rcx, %rax");
                    }
                    (IrBinOp::Sub, t) if t.is_integer() => {
                        self.emit("    subq %rcx, %rax");
                    }
                    (IrBinOp::Mul, t) if t.is_integer() => {
                        self.emit("    imulq %rcx, %rax");
                    }
                    (IrBinOp::Div, t) if t.is_integer() => {
                        self.emit("    cqo");
                        self.emit("    idivq %rcx");
                    }
                    (IrBinOp::Mod, t) if t.is_integer() => {
                        self.emit("    cqo");
                        self.emit("    idivq %rcx");
                        self.emit("    movq %rdx, %rax");
                    }
                    (IrBinOp::Eq, _) => {
                        self.emit("    cmpq %rcx, %rax");
                        self.emit("    sete %al");
                        self.emit("    movzbq %al, %rax");
                    }
                    (IrBinOp::Ne, _) => {
                        self.emit("    cmpq %rcx, %rax");
                        self.emit("    setne %al");
                        self.emit("    movzbq %al, %rax");
                    }
                    (IrBinOp::Lt, t) if t.is_signed() => {
                        self.emit("    cmpq %rcx, %rax");
                        self.emit("    setl %al");
                        self.emit("    movzbq %al, %rax");
                    }
                    (IrBinOp::Le, t) if t.is_signed() => {
                        self.emit("    cmpq %rcx, %rax");
                        self.emit("    setle %al");
                        self.emit("    movzbq %al, %rax");
                    }
                    (IrBinOp::Gt, t) if t.is_signed() => {
                        self.emit("    cmpq %rcx, %rax");
                        self.emit("    setg %al");
                        self.emit("    movzbq %al, %rax");
                    }
                    (IrBinOp::Ge, t) if t.is_signed() => {
                        self.emit("    cmpq %rcx, %rax");
                        self.emit("    setge %al");
                        self.emit("    movzbq %al, %rax");
                    }
                    (IrBinOp::And, Type::Bool) => {
                        self.emit("    andq %rcx, %rax");
                    }
                    (IrBinOp::Or, Type::Bool) => {
                        self.emit("    orq %rcx, %rax");
                    }
                    _ => {}
                }

                self.emit(&format!("    movq %rax, {}(%rbp)", dst_offset));
            }
            Instruction::UnOp { dst, op, src, ty } => {
                let dst_offset = self.var_offsets[dst];
                self.load_value(src, "%rax", ty);

                match op {
                    IrUnOp::Neg => {
                        self.emit("    negq %rax");
                    }
                    IrUnOp::Not => {
                        self.emit("    xorq $1, %rax");
                    }
                }

                self.emit(&format!("    movq %rax, {}(%rbp)", dst_offset));
            }
            Instruction::Call {
                dst, func, args, ..
            } => {
                let param_regs = ["%rdi", "%rsi", "%rdx", "%rcx", "%r8", "%r9"];
                for (i, arg) in args.iter().enumerate() {
                    if i < 6 {
                        self.load_value(arg, param_regs[i], &Type::I64);
                    }
                }

                self.emit(&format!("    call {}", Self::mangle_name(func)));

                if let Some(dst_var) = dst {
                    let dst_offset = self.var_offsets[dst_var];
                    self.emit(&format!("    movq %rax, {}(%rbp)", dst_offset));
                }
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
                match ty.size() {
                    8 => {
                        self.load_value(src, "%rax", ty);
                        self.emit(&format!("    movq %rax, {}(%rbp)", dst_offset));
                    }
                    4 => {
                        self.load_value(src, "%rax", ty);
                        self.emit(&format!("    movl %eax, {}(%rbp)", dst_offset));
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
                    self.load_value(v, "%rax", &Type::I64);
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

    fn load_value(&mut self, val: &Value, reg: &str, ty: &Type) {
        match val {
            Value::ConstI64(n) => {
                self.emit(&format!("    movq ${}, {}", n, reg));
            }
            Value::ConstI32(n) => {
                self.emit(&format!("    movl ${}, {}", n, Self::reg32(reg)));
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
                // 64-bit register, zero-extending narrower types so the upper
                // bits are well-defined for the subsequent op/compare.
                match ty.size() {
                    8 => self.emit(&format!("    movq {}(%rbp), {}", offset, reg)),
                    // `movl` into the 32-bit sub-register zero-extends into the
                    // full 64-bit register on x86_64.
                    4 => self.emit(&format!("    movl {}(%rbp), {}", offset, Self::reg32(reg))),
                    1 => self.emit(&format!("    movzbq {}(%rbp), {}", offset, reg)),
                    _ => {}
                }
            }
            _ => {}
        }
    }

    /// Map a 64-bit register name (e.g. `%rax`) to its 32-bit sub-register
    /// (`%eax`). A `movl` into the 32-bit form zero-extends into the full
    /// 64-bit register on x86_64.
    fn reg32(reg: &str) -> String {
        match reg {
            "%rax" => "%eax".into(),
            "%rcx" => "%ecx".into(),
            "%rdx" => "%edx".into(),
            "%rbx" => "%ebx".into(),
            "%rsi" => "%esi".into(),
            "%rdi" => "%edi".into(),
            "%r8" => "%r8d".into(),
            "%r9" => "%r9d".into(),
            "%r10" => "%r10d".into(),
            "%r11" => "%r11d".into(),
            // Fallback: strip the leading `r` is wrong for these, so just
            // reuse the 64-bit name (still valid, just no narrowing).
            other => other.into(),
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
        assert!(asm.contains("main:"));
        assert!(asm.contains("movq $3, %rax"));
        assert!(asm.contains("ret"));
    }

    #[test]
    fn test_compile_constant_main() {
        // (+ 1 2) folds to a constant; backend should emit the literal in %rax.
        let asm = compile_ok("(define (main) : i64 (+ 1 2))");
        assert!(asm.contains("    .globl main"));
        assert!(asm.contains("main:"));
        assert!(asm.contains("movq $3, %rax"));
    }

    #[test]
    fn test_compile_add_function() {
        // Parameters are loaded from registers into stack slots, added, returned.
        let asm = compile_ok("(define (add [a : i64] [b : i64]) : i64 (+ a b))");
        // Mangled non-main name.
        assert!(asm.contains("_tl_add:"), "asm:\n{}", asm);
        // Prologue moves the two integer params from rdi/rsi to stack slots.
        assert!(asm.contains("mov %rdi,"), "asm:\n{}", asm);
        assert!(asm.contains("mov %rsi,"), "asm:\n{}", asm);
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
    fn test_reject_float_constant() {
        let err = compile_err("(define (pi) : f64 3.14)");
        assert!(err.contains("backend:"), "err: {}", err);
        assert!(err.contains("floating-point"), "err: {}", err);
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
}
