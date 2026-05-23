//! Cross-platform proof that the nested-pattern evaluator
//! (`tests/integration/nested_eval.tl`) compiles all the way to valid x86_64
//! assembly.
//!
//! This is the end-to-end witness for NESTED PATTERN MATCHING (#41). The
//! evaluator's `SCons` arm uses a single nested pattern
//! `(SCons (SSym name) rest)` to destructure two enum layers at once, binding
//! the operator symbol `name : String` (projected out of the inner `SSym`) and
//! the argument spine `rest : Sexpr` together — folding away the single-level
//! `sexpr-sym` projection helper that flat matching would have required.
//!
//! Like the other `*_compile.rs` tests this only invokes the `compile`
//! subcommand, so it runs everywhere — including the Windows dev box — and
//! asserts on the emitted assembly text. The assemble+link+run check (asserting
//! `(+ 1 (* 2 3))` evaluates to exit code 7) is Linux-gated in
//! `tests/integration.rs`.

use std::fs;
use std::path::PathBuf;
use std::process::Command;

#[test]
fn nested_eval_tl_compiles_to_assembly() {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let source_path = manifest_dir
        .join("tests")
        .join("integration")
        .join("nested_eval.tl");

    let work_dir = manifest_dir.join("target").join("nested-eval-compile-test");
    fs::create_dir_all(&work_dir).expect("create nested_eval compile test work dir");
    let asm_path = work_dir.join("nested_eval.s");

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
        "nested_eval.tl compile step failed\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr,
    );

    let asm = fs::read_to_string(&asm_path).expect("read generated nested_eval assembly");

    // The whole program lowered: no stubbed-out / unimplemented constructs.
    assert!(
        !asm.contains("# TODO"),
        "nested_eval assembly still contains a # TODO marker:\n{}",
        asm,
    );

    // A real program entry point exists.
    assert!(
        asm.contains("main:"),
        "nested_eval assembly has no main:\n{}",
        asm
    );

    // The evaluator and its remaining flat projections were emitted.
    for sym in ["_tl_eval_sexpr:", "_tl_sexpr_head:", "_tl_sexpr_tail:"] {
        assert!(
            asm.contains(sym),
            "nested_eval assembly is missing expected symbol {}:\n{}",
            sym,
            asm,
        );
    }

    // The nested pattern emits a SECOND tag-dispatch block inside the SCons arm
    // (testing the inner SSym's tag); the lowerer labels it `match_nested`.
    // Its presence is the proof that a sub-variant pattern was lowered as a
    // nested tag compare + branch rather than a flat field bind.
    assert!(
        asm.contains("match_nested"),
        "nested_eval assembly has no nested tag-dispatch block (match_nested):\n{}",
        asm,
    );

    // The dispatch on the bound operator symbol goes through string equality.
    assert!(
        asm.contains("call tl_string_eq") || asm.contains("call _tl_string_eq"),
        "nested_eval assembly does not dispatch via string equality:\n{}",
        asm,
    );

    // The recursive tree walk: eval-sexpr calls itself on the sub-expressions.
    assert!(
        asm.contains("call _tl_eval_sexpr"),
        "nested_eval assembly has no recursive eval-sexpr call:\n{}",
        asm,
    );

    // The malformed-shape path lowers `(panic ...)` to the private abort runtime.
    assert!(
        asm.contains("call .L_tl_abort"),
        "nested_eval assembly is missing the panic abort path (.L_tl_abort):\n{}",
        asm,
    );
}
