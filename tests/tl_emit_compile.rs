//! Cross-platform proof that the TypeLisp self-hosting emitter slice compiles.
//!
//! `examples/tl_emit.tl` is the first backend-shaped TypeLisp program for
//! #155/#156: it walks a tiny arithmetic `Expr` tree, wraps the emitted body in
//! a runnable `main` + `_start` assembly skeleton, and prints that full `.s`.
//! This test only compiles the program so it runs on Windows too; the Linux
//! integration test executes it, assembles the printed text, and asserts exit 7.

use std::fs;
use std::path::PathBuf;
use std::process::Command;

#[test]
fn tl_emit_tl_compiles_to_assembly() {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let source_path = manifest_dir.join("examples").join("tl_emit.tl");

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
        "tl_emit.tl compile step failed\nstdout:\n{}\nstderr:\n{}",
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
        "_tl_emit_bin:",
        "_tl_emit_expr:",
        "_tl_emit_program:",
        // refs #163: the variable/let codegen path - the name->slot lookup, the
        // var load + let store emitters, the frame-sizing helpers.
        "_tl_cenv_lookup:",
        "_tl_emit_var:",
        "_tl_emit_let:",
        "_tl_let_depth:",
        "_tl_emit_frame_reserve:",
        "_tl_emit_frame_restore:",
        "_tl_sample:",
        "tl_int_to_string:",
        "tl_string_concat:",
        "tl_print_str:",
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
        "call _tl_emit_expr",
        "call _tl_emit_op",
        "call tl_int_to_string",
        "call tl_string_concat",
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
        "    addq %rcx, %rax\\n",
        "    subq %rcx, %rax\\n",
        "    imulq %rcx, %rax\\n",
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
        // refs #163: the let/var data fragments the emitter splices at run time -
        // the slot store (`movq %rax, -OFF(%rbp)`), the slot load
        // (`movq -OFF(%rbp), %rax`), and the frame reservation `sub $K, %rsp` /
        // teardown `add $K, %rsp`. Each appears as a `.string` datum.
        "    movq %rax, -",
        "(%rbp)\\n",
        "(%rbp), %rax\\n",
        "    sub $",
        "    add $",
    ] {
        assert!(
            asm.contains(literal),
            "tl_emit assembly is missing string literal {:?}:\n{}",
            literal,
            asm,
        );
    }
}
