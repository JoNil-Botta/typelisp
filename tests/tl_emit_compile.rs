//! Cross-platform proof that the TypeLisp self-hosting emitter slice compiles.
//!
//! `selfhost/emit.tl` is the first backend-shaped TypeLisp program for
//! #155/#156/#163: it imports the main-less emitter core, walks a tiny arithmetic
//! `Expr` tree, wraps the emitted body in a runnable `main` + `_start` assembly
//! skeleton, and prints that full `.s`. This test only compiles the program so it
//! runs on Windows too; the Linux integration test executes it, assembles the
//! printed text, and asserts exit 7.

use std::fs;
use std::path::PathBuf;
use std::process::Command;

#[test]
fn tl_emit_tl_compiles_to_assembly() {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let source_path = manifest_dir.join("selfhost").join("emit.tl");

    let work_dir = manifest_dir.join("target").join("tl-emit-compile-test");
    fs::create_dir_all(&work_dir).expect("create tl_emit compile test work dir");
    let asm_path = work_dir.join("tl_emit.s");

    let output = Command::new(env!("CARGO_BIN_EXE_typelisp"))
        .arg("compile")
        .arg(&source_path)
        .arg("-o")
        .arg(&asm_path)
        .output()
        .expect("run typelisp compile");

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        output.status.success(),
        "emit.tl compile step failed\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr,
    );

    let asm = fs::read_to_string(&asm_path).expect("read generated tl_emit assembly");

    assert!(
        !asm.contains("# TODO"),
        "tl_emit assembly still contains a # TODO marker:\n{}",
        asm,
    );
    assert_eq!(
        asm.matches("\nmain:").count() + usize::from(asm.starts_with("main:")),
        1,
        "tl_emit assembly must have exactly one main:\n{}",
        asm,
    );

    for sym in [
        "_tl_emit_int:",
        "_tl_emit_op:",
        "_tl_sym_i64_empty:",
        "_tl_sym_i64_bind:",
        "_tl_sym_i64_lookup:",
        "_tl_sym_i64_contains:",
        "_tl_cenv_lookup:",
        "_tl_emit_var:",
        "_tl_emit_bin:",
        "_tl_emit_let:",
        "_tl_emit_if:",
        "_tl_expr_list_count:",
        "_tl_str_list_count:",
        "_tl_str_list_append_one:",
        "_tl_expr_list_collect_strings:",
        "_tl_collect_strings:",
        "_tl_collect_item_strings:",
        "_tl_collect_items_strings:",
        "_tl_string_index_in:",
        "_tl_string_index:",
        "_tl_char_code:",
        "_tl_octal_digit:",
        "_tl_octal_escape:",
        "_tl_escape_string_byte:",
        "_tl_escape_string:",
        "_tl_quoted_gas_string:",
        "_tl_string_label:",
        "_tl_emit_rodata_entries:",
        "_tl_emit_rodata:",
        "_tl_checked_max_six:",
        "_tl_arg_reg:",
        "_tl_bind_params:",
        "_tl_emit_param_spills:",
        "_tl_emit_call_arg_pushes:",
        "_tl_emit_call_arg_pops:",
        "_tl_emit_call:",
        "_tl_function_frame_size:",
        "_tl_emit_def:",
        "_tl_emit_defs:",
        "_tl_fresh_label:",
        "_tl_emit_entry:",
        "_tl_emit_str:",
        "_tl_emit_print:",
        "_tl_emit_expr_in:",
        "_tl_emit_expr:",
        "_tl_max_let_depth:",
        "_tl_frame_size:",
        "_tl_emit_program_with_defs:",
        "_tl_emit_program:",
        "_tl_sample:",
        "tl_int_to_string:",
        "tl_string_concat:",
        "tl_string_eq:",
        "tl_substring:",
        "tl_print_str:",
        "tl_oob_abort:",
        "tl_alloc:",
    ] {
        assert!(
            asm.contains(sym),
            "tl_emit assembly is missing expected symbol {}:\n{}",
            sym,
            asm,
        );
    }

    for call in [
        "call _tl_emit_expr_in",
        "call _tl_emit_let",
        "call _tl_emit_if",
        "call _tl_emit_call",
        "call _tl_emit_call_arg_pushes",
        "call _tl_emit_call_arg_pops",
        "call _tl_emit_param_spills",
        "call _tl_bind_params",
        "call _tl_collect_strings",
        "call _tl_collect_items_strings",
        "call _tl_emit_rodata",
        "call _tl_emit_rodata_entries",
        "call _tl_emit_str",
        "call _tl_emit_print",
        "call _tl_string_index",
        "call _tl_string_label",
        "call _tl_escape_string",
        "call _tl_escape_string_byte",
        "call _tl_octal_escape",
        "call _tl_octal_digit",
        "call _tl_quoted_gas_string",
        "call _tl_emit_def",
        "call _tl_emit_defs",
        "call _tl_emit_entry",
        "call _tl_emit_program_with_defs",
        "call _tl_fresh_label",
        "call _tl_emit_op",
        "call _tl_expr_list_count",
        "call _tl_str_list_count",
        "call _tl_checked_max_six",
        "call _tl_arg_reg",
        "call _tl_sym_i64_empty",
        "call _tl_sym_i64_bind",
        "call _tl_sym_i64_lookup",
        "call _tl_max_let_depth",
        "call tl_int_to_string",
        "call tl_string_concat",
        "call tl_string_eq",
        "call tl_substring",
        "call tl_print_str",
    ] {
        assert!(
            asm.contains(call),
            "tl_emit assembly is missing expected call {}:\n{}",
            call,
            asm,
        );
    }

    for literal in [
        "    movq $",
        ", %rax\\n",
        "    pushq %rax\\n",
        "    movq %rax, %rcx\\n",
        "    popq %rax\\n",
        "    movq ",
        "(%rbp)",
        "    sub $",
        "    add $",
        "    addq %rcx, %rax\\n",
        "    subq %rcx, %rax\\n",
        "    imulq %rcx, %rax\\n",
        // refs #176: string literal collection and literal-only print lowering.
        "    .section .rodata\\n",
        ".Lstr_",
        "    .string ",
        "    leaq ",
        "(%rip), %rax\\n",
        "(%rip), %rsi\\n",
        "    movq $1, %rdi\\n",
        "    movq $1, %rax\\n",
        "    syscall\\n",
        "    movq $0, %rax\\n",
        "emit: missing string literal",
        "emit: print expects string literal",
        // refs #167/#173: comparison and conditional-branch lowering. The
        // operators stage a `cmpq` + `setcc` + `movzbq`; `if` emits a `cmpq $0`
        // test, a `je` to a fresh `.Lelse_` label, a `jmp` to a fresh `.Lend_`
        // label, and the two local labels themselves.
        "    cmpq %rcx, %rax\\n    setl %al\\n    movzbq %al, %rax\\n",
        "    cmpq %rcx, %rax\\n    sete %al\\n    movzbq %al, %rax\\n",
        "    cmpq %rcx, %rax\\n    setle %al\\n    movzbq %al, %rax\\n",
        "    cmpq %rcx, %rax\\n    setg %al\\n    movzbq %al, %rax\\n",
        "    cmpq %rcx, %rax\\n    setge %al\\n    movzbq %al, %rax\\n",
        "    cmpq %rcx, %rax\\n    setne %al\\n    movzbq %al, %rax\\n",
        "    cmpq $0, %rax\\n",
        "    je ",
        "    jmp ",
        ".Lelse_",
        ".Lend_",
        // refs #169: direct calls and user-defined function blocks in the
        // self-hosted emitter. Calls evaluate and push args left-to-right, pop
        // into the SysV integer arg registers in reverse, then emit `call name`.
        "    popq ",
        "    call ",
        "%rdi",
        "%rsi",
        "%rdx",
        "%rcx",
        "%r8",
        "%r9",
        "emit: too many call args",
        "emit: too many params",
        "    mov %rbp, %rsp\\n",
        "    .text\\n",
        "    .globl main\\n",
        "    .globl _start\\n\\n",
        "main:\\n",
        "    push %rbp\\n",
        "    mov %rsp, %rbp\\n",
        "    pop %rbp\\n",
        "    ret\\n\\n",
        "_start:\\n",
        "    call main\\n",
        "    movq %rax, %rdi\\n",
        "    movq $60, %rax\\n",
        "    syscall\\n",
    ] {
        assert!(
            asm.contains(literal),
            "tl_emit assembly is missing string literal {:?}:\n{}",
            literal,
            asm,
        );
    }
}
