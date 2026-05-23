//! Cross-platform proof that the TypeLisp self-hosting define + calls slice
//! compiles.
//!
//! `examples/tl_define.tl` is the define/ECall codegen slice (#169): it imports
//! the main-less emitter core, builds the Item AST for a recursive `fact`
//! program, and `emit-items` lowers each `define` to its own `<name>:` block
//! under the System V AMD64 calling convention (prologue, parameter-register
//! spill, `ECall` push/pop-into-registers + `call`, epilogue). `main` prints the
//! full runnable `.s`. This test only COMPILES the program so it runs on Windows
//! too; the Linux integration test executes the printed program and asserts the
//! recursive exit status 120.

use std::fs;
use std::path::PathBuf;
use std::process::Command;

#[test]
fn tl_define_tl_compiles_to_assembly() {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let source_path = manifest_dir.join("examples").join("tl_define.tl");

    let work_dir = manifest_dir.join("target").join("tl-define-compile-test");
    fs::create_dir_all(&work_dir).expect("create tl_define compile test work dir");
    let asm_path = work_dir.join("tl_define.s");

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
        "tl_define.tl compile step failed\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr,
    );

    let asm = fs::read_to_string(&asm_path).expect("read generated tl_define assembly");

    assert!(
        !asm.contains("# TODO"),
        "tl_define assembly still contains a # TODO marker:\n{}",
        asm,
    );
    assert_eq!(
        asm.matches("\nmain:").count() + usize::from(asm.starts_with("main:")),
        1,
        "tl_define assembly must have exactly one main:\n{}",
        asm,
    );

    // The new define/call emitter helpers and the demo's own AST builders all
    // link into the one concatenated program.
    for sym in [
        "_tl_arg_reg:",
        "_tl_emit_push_args:",
        "_tl_emit_pop_args:",
        "_tl_emit_call:",
        "_tl_bind_params:",
        "_tl_emit_spill_params:",
        "_tl_emit_fn_block:",
        "_tl_emit_fn_blocks:",
        "_tl_emit_items:",
        "_tl_fact_body:",
        "_tl_program:",
        "tl_int_to_string:",
        "tl_string_concat:",
        "tl_print_str:",
        "tl_alloc:",
    ] {
        assert!(
            asm.contains(sym),
            "tl_define assembly is missing expected symbol {}:\n{}",
            sym,
            asm,
        );
    }

    for call in [
        "call _tl_emit_items",
        "call _tl_emit_fn_block",
        "call _tl_emit_call",
        "call _tl_emit_push_args",
        "call _tl_emit_pop_args",
        "call _tl_arg_reg",
        "call _tl_emit_spill_params",
        "call _tl_bind_params",
    ] {
        assert!(
            asm.contains(call),
            "tl_define assembly is missing expected call {}:\n{}",
            call,
            asm,
        );
    }

    // The emitter's define/call output text appears as `.string` data: the
    // parameter-register spill, the call-argument push/pop sequence, the `call`
    // mnemonic, the per-function prologue/epilogue, and the SysV argument
    // register names produced by `arg-reg`.
    for literal in [
        "    movq ",
        "    pushq %rax\\n",
        "    popq ",
        "    call ",
        "    push %rbp\\n",
        "    mov %rsp, %rbp\\n",
        "    pop %rbp\\n",
        "    ret\\n\\n",
        "%rdi",
        "%rsi",
        "%r9",
        "_start:\\n",
        "    call main\\n",
        "    movq $60, %rax\\n",
        "    syscall\\n",
    ] {
        assert!(
            asm.contains(literal),
            "tl_define assembly is missing string literal {:?}:\n{}",
            literal,
            asm,
        );
    }
}
