#![allow(dead_code)]

use crate::ir::{BinOp as IrBinOp, Function, Instruction, Program, UnOp as IrUnOp, Value, VarId};
use crate::types::Type;

/// x86_64 assembly code generator
/// Target: Linux, System V AMD64 ABI
pub struct X86_64Backend {
    output: String,
    label_counter: u32,
    stack_size: i32,
    var_offsets: std::collections::HashMap<VarId, i32>,
}

impl X86_64Backend {
    pub fn new() -> Self {
        X86_64Backend {
            output: String::new(),
            label_counter: 0,
            stack_size: 0,
            var_offsets: std::collections::HashMap::new(),
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

        // Allocate space for locals
        for (var, ty) in &func.locals {
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
            self.emit(&format!("{}.{}", name, block.label));
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
                self.emit(&format!("    jnz {}", true_label));
                self.emit(&format!("    jmp {}", false_label));
            }
            Instruction::Jump(label) => {
                self.emit(&format!("    jmp {}", label));
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
                self.emit(&format!("    movl ${}, {}", n, &reg[1..]));
            }
            Value::ConstBool(b) => {
                let n = if *b { 1 } else { 0 };
                self.emit(&format!("    movq ${}, {}", n, reg));
            }
            Value::Var(v) => {
                let offset = self.var_offsets[v];
                match ty.size() {
                    8 => self.emit(&format!("    movq {}(%rbp), {}", offset, reg)),
                    4 => self.emit(&format!("    movl {}(%rbp), {}", offset, &reg[1..])),
                    1 => self.emit(&format!("    movb {}(%rbp), {}", offset, &reg[1..])),
                    _ => {}
                }
            }
            _ => {}
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

pub fn generate_assembly(program: &Program) -> String {
    let mut backend = X86_64Backend::new();
    backend.generate(program)
}
