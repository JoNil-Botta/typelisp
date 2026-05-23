//! Cross-platform proof that the TypeLisp asm-text emitter
//! (`tests/integration/tl_emit.tl`) compiles all the way to valid x86_64
//! assembly.
//!
//! `tl_emit.tl` is the first slice of TypeLisp's self-hosted CODE GENERATOR
//! (#27/#155): an `emit-expr : Expr -> String` STACK MACHINE that produces the
//! x86_64 assembly TEXT for the integer + `+`/`-`/`*` subset of the compiler's
//! arithmetic AST — `(defenum Expr (ENum i64) (EAdd Expr Expr) (ESub Expr Expr)
//! (EMul Expr Expr))`, the same recursive `Expr` shape `parser.tl` builds
//! (heap-pointer payloads, #111). Each sub-expression leaves its result in
//! `%rax`; a binary node pushes the left operand, computes the right into
//! `%rcx`, pops the left back into `%rax`, then emits the op mnemonic — mirroring
//! the Rust backend's own integer-arithmetic emission
//! (`src/backend/mod.rs:2198-2213`: `addq`/`subq`/`imulq %rcx, %rax`). `main`
//! emits the body asm for `(+ 1 (* 2 3))` and prints it via `print-string`.
//!
//! Like the other `*_compile.rs` tests this only invokes the `compile`
//! subcommand, so it runs everywhere — including the Windows dev box — and
//! asserts on the emitted assembly text. The assemble+link+run check (which
//! asserts the program's PRINTED asm text exactly) is Linux-gated in
//! `tests/integration.rs`.

use std::fs;
use std::path::PathBuf;
use std::process::Command;

#[test]
fn tl_emit_tl_compiles_to_assembly() {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let source_path = manifest_dir
        .join("tests")
        .join("integration")
        .join("tl_emit.tl");

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

    // The whole emitter lowered: no stubbed-out / unimplemented constructs.
    assert!(
        !asm.contains("# TODO"),
        "tl_emit assembly still contains a # TODO marker:\n{}",
        asm,
    );

    // A real program entry point exists.
    assert!(
        asm.contains("main:"),
        "tl_emit assembly has no main:\n{}",
        asm
    );

    // The emitter's own functions were emitted (TypeLisp prefixes user symbols
    // with `_tl_`): the recursive `emit-expr` code generator and its shared
    // binary-op helper `emit-binop`.
    for sym in ["_tl_emit_expr:", "_tl_emit_binop:"] {
        assert!(
            asm.contains(sym),
            "tl_emit assembly is missing expected emitter symbol {}:\n{}",
            sym,
            asm,
        );
    }

    // `emit-expr` is genuinely RECURSIVE: a binary node re-enters `emit-expr` on
    // each child, so `emit-binop` calls `emit-expr` twice and `main` calls it
    // once. At least two `call _tl_emit_expr` sites prove the post-order tree
    // walk (not a single flat emission).
    assert!(
        asm.matches("call _tl_emit_expr").count() >= 2,
        "tl_emit assembly shows no recursive emit-expr calls (stack-machine tree walk):\n{}",
        asm,
    );

    // Each `Expr` node is heap-promoted (recursive enum payloads are
    // heap-pointer indirections, #111), so building the sample AST
    // `(EAdd (ENum 1) (EMul (ENum 2) (ENum 3)))` allocates each constructor
    // through the runtime allocator.
    assert!(
        asm.contains("call tl_alloc"),
        "tl_emit assembly does not heap-allocate its Expr AST nodes via tl_alloc:\n{}",
        asm,
    );

    // The emitted-asm STRING LITERALS are the load-bearing payload: the emitter
    // assembles its output from these instruction-text fragments via
    // `string-append`, so each must reach the read-only data as a `.string`
    // entry. This is the actual x86_64 the emitter produces — the literal-level
    // proof that `emit-expr` emits real machine-code text (the runtime exactness
    // of the assembled sequence is Linux-verified in tests/integration.rs).
    for lit in [
        "\"    movq $\"",
        "\", %rax\\n\"",
        "\"    pushq %rax\\n\"",
        "\"    movq %rax, %rcx\\n\"",
        "\"    popq %rax\\n\"",
        "\"    addq %rcx, %rax\\n\"",
        "\"    subq %rcx, %rax\\n\"",
        "\"    imulq %rcx, %rax\\n\"",
    ] {
        assert!(
            asm.contains(&format!(".string {lit}")),
            "tl_emit assembly is missing the emitted-asm string literal {lit} \
             (the actual x86_64 text the emitter produces):\n{}",
            asm,
        );
    }

    // The output text is assembled with the host `string-append` builtin, which
    // lowers to the emit-on-demand `tl_string_concat` runtime (copies BOTH
    // operands' bytes into ONE fresh heap String). Its definition AND at least
    // one call site must be present.
    assert!(
        asm.contains("tl_string_concat:"),
        "tl_emit assembly is missing the tl_string_concat runtime helper (string-append):\n{}",
        asm,
    );
    assert!(
        asm.contains("call tl_string_concat"),
        "tl_emit assembly shows no string-append call (asm text not assembled):\n{}",
        asm,
    );

    // An `(ENum n)` literal renders `n` as decimal text via the host
    // `int->string` builtin, which lowers to the emit-on-demand
    // `tl_int_to_string` runtime (heap-allocates the decimal-text String). Its
    // definition AND a call site must be present.
    assert!(
        asm.contains("tl_int_to_string:"),
        "tl_emit assembly is missing the tl_int_to_string runtime helper (int->string):\n{}",
        asm,
    );
    assert!(
        asm.contains("call tl_int_to_string"),
        "tl_emit assembly shows no int->string call (literal operand not rendered):\n{}",
        asm,
    );

    // `main` prints the emitted asm text via the host `print-string` builtin,
    // which lowers to the emit-on-demand `tl_print_str` write(2)-syscall runtime
    // (raw bytes to fd 1). Its definition AND a call site must be present.
    assert!(
        asm.contains("tl_print_str:"),
        "tl_emit assembly is missing the tl_print_str runtime helper (print-string):\n{}",
        asm,
    );
    assert!(
        asm.contains("call tl_print_str"),
        "tl_emit assembly shows no print-string call (emitted asm not printed):\n{}",
        asm,
    );
}
