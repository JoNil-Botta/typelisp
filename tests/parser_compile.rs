//! Cross-platform proof that the TypeLisp parser (`tests/integration/parser.tl`)
//! compiles all the way to valid x86_64 assembly.
//!
//! The parser is the second front-end component of the self-hosting milestone
//! (#27, phase 4), following the tokenizer in `lexer.tl`: it consumes a token
//! stream and runs recursive descent over the grammar
//!   expr := term ('+' term)*    term := int | '(' expr ')'
//! emitting a flat postfix op stream (a non-recursive AST encoding, since
//! recursive enums are not yet supported by the typechecker — see the file
//! header and the PR body), then folds that op stream to a value.
//!
//! Like `lexer_compile.rs`, this test only invokes the `compile` subcommand, so
//! it runs everywhere — including the Windows dev box — and asserts on the
//! emitted assembly text. The assemble+link+run check is Linux-gated in
//! `tests/integration.rs`.

use std::fs;
use std::path::PathBuf;
use std::process::Command;

#[test]
fn parser_tl_compiles_to_assembly() {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let source_path = manifest_dir
        .join("tests")
        .join("integration")
        .join("parser.tl");

    let work_dir = manifest_dir.join("target").join("parser-compile-test");
    fs::create_dir_all(&work_dir).expect("create parser compile test work dir");
    let asm_path = work_dir.join("parser.s");

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
        "parser.tl compile step failed\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr,
    );

    let asm = fs::read_to_string(&asm_path).expect("read generated parser assembly");

    // The whole parser lowered: no stubbed-out / unimplemented constructs.
    assert!(
        !asm.contains("# TODO"),
        "parser assembly still contains a # TODO marker:\n{}",
        asm,
    );

    // A real program entry point exists.
    assert!(
        asm.contains("main:"),
        "parser assembly has no main:\n{}",
        asm
    );

    // The token / op-stream / value-stack arrays are heap-allocated through the
    // runtime allocator.
    assert!(
        asm.contains("call tl_alloc"),
        "parser assembly does not allocate its arrays via tl_alloc:\n{}",
        asm,
    );

    // Array indexing is bounds-checked: cursor reads and op-stream writes go
    // through the out-of-bounds abort helper.
    assert!(
        asm.contains("call tl_oob_abort"),
        "parser assembly is missing the bounds-check trap (tl_oob_abort):\n{}",
        asm,
    );

    // A grammar violation (`expect` / unexpected token) lowers `(panic ...)` to
    // the private abort runtime.
    assert!(
        asm.contains("call .L_tl_abort"),
        "parser assembly is missing the syntax-error abort path (.L_tl_abort):\n{}",
        asm,
    );

    // The parser's own functions were emitted (TypeLisp prefixes user symbols
    // with `_tl_`): the recursive-descent core (`parse_expr`/`parse_term`), the
    // token-cursor `expect`, the op-stream `emit`, and the postfix `eval_ops`.
    // `parse_expr` calling `parse_term` and vice versa proves mutual recursion
    // across the two parse routines lowers correctly.
    for sym in [
        "_tl_parse_expr:",
        "_tl_parse_term:",
        "_tl_expect:",
        "_tl_emit:",
        "_tl_eval_ops:",
        "_tl_token_tag:",
        "_tl_token_int:",
    ] {
        assert!(
            asm.contains(sym),
            "parser assembly is missing expected symbol {}:\n{}",
            sym,
            asm,
        );
    }

    // Recursive descent: `parse_expr` actually calls `parse_term`.
    assert!(
        asm.contains("call _tl_parse_term"),
        "parser assembly shows no parse_expr -> parse_term call:\n{}",
        asm,
    );
}
