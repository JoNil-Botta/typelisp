#![allow(dead_code)]

use crate::ir::{BinOp as IrBinOp, Function, Instruction, Program, UnOp as IrUnOp, Value, VarId};
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
}

/// Validate that an IR program only uses constructs the backend can faithfully
/// lower. The backend currently supports scalar arithmetic, unary/binary ops,
/// comparisons, direct calls and `return` over integer/bool/char scalars.
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

    let unsupported = |what: &str| {
        Err(format!(
            "backend: function '{}' uses an unsupported construct ({}). \
             The x86_64 backend currently supports scalar arithmetic, comparisons, \
             unary/binary operators, direct function calls and recursion. \
             Control flow (if/while), let/set! bindings, tuples, arrays, lambdas, \
             strings and floats are not yet wired (see issues #10/#13).",
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

impl X86_64Backend {
    pub fn new() -> Self {
        X86_64Backend {
            output: String::new(),
            label_counter: 0,
            stack_size: 0,
            var_offsets: std::collections::HashMap::new(),
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
