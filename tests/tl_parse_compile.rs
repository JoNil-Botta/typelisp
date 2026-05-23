//! Cross-platform proof that the TypeLisp self-hosting PARSER slice compiles.
//!
//! `selfhost/parse.tl` is the middle of the first end-to-end self-hosted
//! pipeline (#154/#163): it imports the `main`-less reader (`lex` + `read` + the
//! `Sexpr` AST) and the `main`-less emitter core, adds `parse : Sexpr -> Expr`
//! and `parse-op : String -> BinOp`, and `main` runs the whole pipeline over a
//! source that uses let, if, and comparison - printing the full runnable `.s`.
//! This test only COMPILES the program so it runs on Windows too; the Linux
//! integration test executes it, assembles the printed text, and asserts exit 1.

use std::fs;
use std::path::PathBuf;
use std::process::Command;

#[test]
fn tl_parse_tl_compiles_to_assembly() {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let source_path = manifest_dir.join("selfhost").join("parse.tl");

    let work_dir = manifest_dir.join("target").join("tl-parse-compile-test");
    fs::create_dir_all(&work_dir).expect("create tl_parse compile test work dir");
    let asm_path = work_dir.join("tl_parse.s");

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
        "parse.tl compile step failed\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr,
    );

    let asm = fs::read_to_string(&asm_path).expect("read generated tl_parse assembly");

    assert!(
        !asm.contains("# TODO"),
        "tl_parse assembly still contains a # TODO marker:\n{}",
        asm,
    );
    assert_eq!(
        asm.matches("\nmain:").count() + usize::from(asm.starts_with("main:")),
        1,
        "tl_parse assembly must have exactly one main:\n{}",
        asm,
    );

    // The parser's own symbols, the imported reader/lexer entry points, and the
    // duplicated emitter helpers all link into the one concatenated program.
    for sym in [
        "_tl_parse:",
        "_tl_parse_op:",
        "_tl_parse_binary:",
        "_tl_parse_let:",
        "_tl_parse_if:",
        "_tl_parse_print:",
        "_tl_lex:",
        "_tl_read:",
        "_tl_cenv_lookup:",
        "_tl_emit_let:",
        "_tl_emit_if:",
        "_tl_emit_str:",
        "_tl_emit_print:",
        "_tl_emit_rodata:",
        "_tl_collect_strings:",
        "_tl_fresh_label:",
        "_tl_emit_expr:",
        "_tl_emit_program:",
        "tl_int_to_string:",
        "tl_string_concat:",
        "tl_print_str:",
        "tl_alloc:",
    ] {
        assert!(
            asm.contains(sym),
            "tl_parse assembly is missing expected symbol {}:\n{}",
            sym,
            asm,
        );
    }

    // `main` drives the whole pipeline: lex -> read -> parse -> emit-program.
    for call in [
        "call _tl_lex",
        "call _tl_read",
        "call _tl_parse",
        "call _tl_parse_if",
        "call _tl_parse_print",
        "call _tl_emit_program",
        "call _tl_emit_let",
        "call _tl_emit_if",
        "call _tl_emit_rodata",
        "call _tl_collect_strings",
        "call _tl_fresh_label",
    ] {
        assert!(
            asm.contains(call),
            "tl_parse assembly is missing expected call {}:\n{}",
            call,
            asm,
        );
    }

    // The literal source string the pipeline is run on appears as a data datum.
    // refs #167/#173: the demo now exercises let + if + comparison together.
    assert!(
        asm.contains(".string \"(let ((x 5)) (if (<= x 5) 1 0))\""),
        "tl_parse assembly is missing the source-string datum:\n{}",
        asm,
    );

    // The emitter's output text - the `.s` the pipeline PRODUCES - appears as
    // `.string` data: the operator instructions and the `main` / `_start`
    // skeleton, including the `imulq`, `_start`, `syscall`, and `$60` markers the
    // brief calls out.
    for literal in [
        ".string \"    movq $",
        ".string \"    addq %rcx, %rax\\n\"",
        ".string \"    subq %rcx, %rax\\n\"",
        ".string \"    imulq %rcx, %rax\\n\"",
        // refs #176: the imported emitter can now emit rodata and inline
        // write(2) calls for literal-only `(print "...")` forms.
        ".string \"    .section .rodata\\n\"",
        ".string \".Lstr_\"",
        ".string \":\\n    .string \"",
        ".string \"    leaq \"",
        ".string \"(%rip), %rax\\n\"",
        ".string \"(%rip), %rsi\\n\"",
        ".string \"    movq $1, %rdi\\n\"",
        ".string \"    movq $1, %rax\\n\"",
        ".string \"    syscall\\n\"",
        ".string \"    movq $0, %rax\\n\"",
        // refs #167/#173: the emitter's comparison + conditional-branch string
        // constants are compiled into the program regardless of the input.
        ".string \"    cmpq %rcx, %rax\\n    setl %al\\n    movzbq %al, %rax\\n\"",
        ".string \"    cmpq %rcx, %rax\\n    sete %al\\n    movzbq %al, %rax\\n\"",
        ".string \"    cmpq %rcx, %rax\\n    setle %al\\n    movzbq %al, %rax\\n\"",
        ".string \"    cmpq %rcx, %rax\\n    setg %al\\n    movzbq %al, %rax\\n\"",
        ".string \"    cmpq %rcx, %rax\\n    setge %al\\n    movzbq %al, %rax\\n\"",
        ".string \"    cmpq %rcx, %rax\\n    setne %al\\n    movzbq %al, %rax\\n\"",
        ".string \"    cmpq $0, %rax\\n\"",
        ".string \"    je \"",
        ".string \"    jmp \"",
        ".string \".Lelse_\"",
        ".string \".Lend_\"",
        ".string \"    sub $\"",
        ".string \"    add $\"",
        ".string \"(%rbp)\"",
        ".string \"    .text\\n\"",
        ".string \"    .globl _start\\n\\n\"",
        ".string \"_start:\\n\"",
        ".string \"    call main\\n\"",
        ".string \"    movq $60, %rax\\n\"",
        ".string \"    syscall\\n\"",
    ] {
        assert!(
            asm.contains(literal),
            "tl_parse assembly is missing emitted string literal {:?}:\n{}",
            literal,
            asm,
        );
    }
}
