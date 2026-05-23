//! Cross-platform proof that the self-hosting x86_64 .s text emitter
//! (`tests/integration/tl_emit.tl`) compiles all the way to valid x86_64
//! assembly.
//!
//! `tl_emit.tl` is the first codegen piece of TypeLisp's self-hosting
//! compiler front end (#27): it emits Intel-syntax x86_64 assembly text
//! for integer arithmetic expressions, using a stack-machine approach
//! matching the Rust backend (src/backend/mod.rs).
//!
//! Like the other `*_compile.rs` tests this only invokes the `compile`
//! subcommand, so it runs everywhere - including the Windows dev box -
//! and asserts on the emitted assembly text. The assemble+link+run check
//! is Linux-gated in `tests/integration.rs`.

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

    // Exactly one main (no imports in this file, but consistent with other tests).
    assert_eq!(
        asm.matches("\nmain:").count() + usize::from(asm.starts_with("main:")),
        1,
        "tl_emit assembly must have exactly one main:\n{}",
        asm,
    );

    // The emitter's functions are emitted (TypeLisp prefixes user symbols with `_tl_`):
    // the tree-walking `emit-expr` and the operator dispatcher `emit-op`.
    for sym in ["_tl_emit_expr:", "_tl_emit_op:"] {
        assert!(
            asm.contains(sym),
            "tl_emit assembly is missing expected emitter symbol {}:\n{}",
            sym,
            asm,
        );
    }

    // Enum constructors and pattern matchers are lowered:
    // EInt and EBin for Expr; OpAdd, OpSub, OpMul for BinOp.
    // The match arms dispatch on tag values 0 through 2.
    assert!(
        asm.contains("call tl_alloc"),
        "tl_emit assembly does not allocate its enum nodes via tl_alloc:\n{}",
        asm,
    );

    // String literals for the emitted assembly fragments reach the read-only data.
    // Each operator and the prefix/suffix of movq are emitted as separate string
    // concat operands.
    for lit in [
        ".string \"    movq $\"",
        ".string \", %rax\\n\"",
        ".string \"    pushq %rax\\n\"",
        ".string \"    movq %rax, %rcx\\n\"",
        ".string \"    popq %rax\\n\"",
        ".string \"    addq %rcx, %rax\\n\"",
        ".string \"    subq %rcx, %rax\\n\"",
        ".string \"    imulq %rcx, %rax\\n\"",
    ] {
        assert!(
            asm.contains(lit),
            "tl_emit assembly is missing expected rodata literal {}:\n{}",
            lit,
            asm,
        );
    }

    // Integer-to-string conversion for the EInt payload is lowered to the
    // emit-on-demand `tl_int_to_string` runtime.
    assert!(
        asm.contains("tl_int_to_string:"),
        "tl_emit assembly is missing the tl_int_to_string runtime helper:\n{}",
        asm,
    );
    assert!(
        asm.contains("call tl_int_to_string"),
        "tl_emit assembly shows no int->string call:\n{}",
        asm,
    );

    // String concatenation is lowered to the emit-on-demand `tl_string_concat`
    // runtime (the nested string-append chain builds each line).
    assert!(
        asm.contains("tl_string_concat:"),
        "tl_emit assembly is missing the tl_string_concat runtime helper:\n{}",
        asm,
    );
    assert!(
        asm.contains("call tl_string_concat"),
        "tl_emit assembly shows no string-append call:\n{}",
        asm,
    );

    // The print-string builtin loweres to the emit-on-demand `tl_print_str`
    // runtime (writes the resulting assembly text to stdout).
    assert!(
        asm.contains("tl_print_str:"),
        "tl_emit assembly is missing the tl_print_str runtime helper:\n{}",
        asm,
    );
    assert!(
        asm.contains("call tl_print_str"),
        "tl_emit assembly shows no print-string call:\n{}",
        asm,
    );

    // `emit-expr` is genuinely recursive: the EBin arm calls itself for the
    // left and right sub-expressions.
    assert!(
        asm.contains("call _tl_emit_expr"),
        "tl_emit assembly shows no recursive emit-expr call:\n{}",
        asm,
    );
    assert!(
        asm.matches("call _tl_emit_expr").count() >= 2,
        "tl_emit assembly shows too few recursive emit-expr calls (EBin left and right):\n{}",
        asm,
    );

    // `test-expr` is emitted as its own zero-arg function.
    assert!(
        asm.contains("_tl_test_expr:"),
        "tl_emit assembly is missing the test-expr helper:\n{}",
        asm,
    );
}
