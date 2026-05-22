#![allow(dead_code)]

use crate::ir::{BinOp as IrBinOp, Function, Instruction, Program, UnOp as IrUnOp, Value, VarId};
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
}

/// Validate that an IR program only uses constructs the backend can faithfully
/// lower. The backend currently supports scalar arithmetic, unary/binary ops,
/// comparisons, direct calls and `return` over integer/bool/char/f64 scalars.
///
/// Constructs that are lowered but NOT yet selected to assembly (`Phi`, memory
/// ops produced by `let`/`set!`, indirect calls, address/GEP arithmetic and
/// `Global` operands) are rejected here with a clear message instead of being
/// silently miscompiled (they would otherwise fall through to a `# TODO`
/// comment and produce wrong code).
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
    let params: HashSet<VarId> = func.params.iter().map(|(v, _)| *v).collect();
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
             unary/binary operators, direct function calls and recursion. \
             Control flow (if/while), let/set! bindings, tuples, arrays, lambdas, \
             strings, f32 values and aggregate values are not yet wired (see issues #10/#13).",
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
                        && matches!(*op, IrBinOp::Mod | IrBinOp::And | IrBinOp::Or)
                    {
                        return unsupported("unsupported f64 binary operator");
                    }
                }
                Instruction::UnOp { op, src, ty, .. } => {
                    check_operand(src).map_err(|w| unsupported_value(&func.name, &w))?;
                    let src_ty = validate_value_type(src, &var_types).unwrap_or_else(|| ty.clone());
                    if src_ty == Type::F64 && *op == IrUnOp::Not {
                        return unsupported("unsupported f64 unary operator");
                    }
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
                // Parameter `Alloc`s are redundant no-ops (the slot is set up by
                // the prologue); any other `Alloc` means a real local that needs
                // memory ops the backend cannot emit yet.
                Instruction::Alloc { var, .. } => {
                    if !params.contains(var) {
                        return unsupported("let/set! local binding (Alloc)");
                    }
                }
                Instruction::Phi { .. } => return unsupported("if-expression (Phi node)"),
                Instruction::Branch { .. } => return unsupported("conditional branch"),
                Instruction::Load { .. } => return unsupported("memory load"),
                Instruction::Store { .. } => return unsupported("memory store"),
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
        self.emit(&format!("{}:", name));

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
                let operand_ty = self.binop_operand_ty(op, lhs, rhs, ty);
                if operand_ty == Type::F64 {
                    self.generate_float_binop(dst_offset, op, lhs, rhs, ty);
                    return;
                }

                self.load_value(lhs, "%rax", &operand_ty);
                self.load_value(rhs, "%rcx", &operand_ty);

                match (op, &operand_ty) {
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

                self.store_gpr_value("%rax", dst_offset, ty);
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
                        IrUnOp::Not => {}
                    }
                    self.store_xmm_value("%xmm0", dst_offset);
                    return;
                }

                self.load_value(src, "%rax", ty);

                match op {
                    IrUnOp::Neg => {
                        self.emit("    negq %rax");
                    }
                    IrUnOp::Not => {
                        self.emit("    xorq $1, %rax");
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

                self.emit(&format!("    call {}", Self::mangle_name(func)));

                if let Some(dst_var) = dst {
                    let dst_offset = self.var_offsets[dst_var];
                    if *ty == Type::F64 {
                        self.store_xmm_value("%xmm0", dst_offset);
                    } else {
                        self.store_gpr_value("%rax", dst_offset, ty);
                    }
                }
            }
            Instruction::Branch {
                cond,
                true_label,
                false_label,
            } => {
                self.load_value(cond, "%rax", &Type::Bool);
                self.emit("    testq %rax, %rax");
                self.emit(&format!("    jnz {}", true_label));
                self.emit(&format!("    jmp {}", false_label));
            }
            Instruction::Jump(label) => {
                self.emit(&format!("    jmp {}", label));
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
                match ty.size() {
                    8 => self.emit(&format!("    movq {}(%rbp), {}", offset, reg)),
                    4 => self.emit(&format!("    movl {}(%rbp), {}", offset, Self::gpr32(reg))),
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
            IrBinOp::Mod | IrBinOp::And | IrBinOp::Or => {}
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

    fn gpr32(reg: &str) -> &str {
        match reg {
            "%rax" => "%eax",
            "%rcx" => "%ecx",
            "%rdx" => "%edx",
            "%rdi" => "%edi",
            "%rsi" => "%esi",
            "%r8" => "%r8d",
            "%r9" => "%r9d",
            _ => reg,
        }
    }

    fn gpr8(reg: &str) -> &str {
        match reg {
            "%rax" => "%al",
            "%rcx" => "%cl",
            "%rdx" => "%dl",
            "%rdi" => "%dil",
            "%rsi" => "%sil",
            "%r8" => "%r8b",
            "%r9" => "%r9b",
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

    // ---- Graceful rejection of out-of-scope constructs -----------------

    #[test]
    fn test_reject_if_expression() {
        // `if` lowers to a Phi node, which is not yet selected to assembly.
        let err = compile_err("(define (max [a : i64] [b : i64]) : i64 (if (> a b) a b))");
        assert!(err.contains("backend:"), "err: {}", err);
        assert!(err.to_lowercase().contains("if") || err.contains("Phi") || err.contains("branch"));
    }

    #[test]
    fn test_reject_let_binding() {
        // `let` lowers to Alloc/Store of a non-parameter local.
        let err =
            compile_err("(define (triple [x : i64]) : i64 (let ([y : i64 (+ x x)]) (+ y x)))");
        assert!(err.contains("backend:"), "err: {}", err);
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
