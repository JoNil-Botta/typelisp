//! Cross-platform proof that the TypeLisp lexer (`tests/integration/lexer.tl`)
//! compiles all the way to valid x86_64 assembly.
//!
//! This is the front end of the self-hosting milestone (#27, phase 4): the
//! first compiler component written *in* TypeLisp. Unlike the
//! assemble+link+run integration tests (which require GNU `as`/`ld` and are
//! gated to Linux), this test only invokes the `compile` subcommand, so it runs
//! everywhere — including the Windows dev box — and asserts on the emitted
//! assembly text.

use std::fs;
use std::path::PathBuf;
use std::process::Command;

#[test]
fn lexer_tl_compiles_to_assembly() {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let source_path = manifest_dir
        .join("tests")
        .join("integration")
        .join("lexer.tl");

    let work_dir = manifest_dir.join("target").join("lexer-compile-test");
    fs::create_dir_all(&work_dir).expect("create lexer compile test work dir");
    let asm_path = work_dir.join("lexer.s");

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
        "lexer.tl compile step failed\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr,
    );

    let asm = fs::read_to_string(&asm_path).expect("read generated lexer assembly");

    // The whole front end lowered: no stubbed-out / unimplemented constructs.
    assert!(
        !asm.contains("# TODO"),
        "lexer assembly still contains a # TODO marker:\n{}",
        asm,
    );

    // A real program entry point exists.
    assert!(
        asm.contains("main:"),
        "lexer assembly has no main:\n{}",
        asm
    );

    // The dynamic token array is heap-allocated through the runtime.
    assert!(
        asm.contains("call tl_alloc"),
        "lexer assembly does not allocate its token array via tl_alloc:\n{}",
        asm,
    );

    // String indexing / array bounds are checked: every `string-ref` and
    // `array-set!` goes through the out-of-bounds abort helper.
    assert!(
        asm.contains("call tl_oob_abort"),
        "lexer assembly is missing the bounds-check trap (tl_oob_abort):\n{}",
        asm,
    );

    // The unexpected-character path lowers `(panic ...)` to the private abort runtime.
    assert!(
        asm.contains("call .L_tl_abort"),
        "lexer assembly is missing the panic abort path (.L_tl_abort):\n{}",
        asm,
    );

    // Identifier tokens slice their text out of the source: the `substring`
    // builtin (#104) lowers to the `tl_substring` runtime helper. This is the
    // proof that identifiers carry their lexeme rather than being skipped.
    assert!(
        asm.contains("tl_substring"),
        "lexer assembly does not slice identifier text via tl_substring:\n{}",
        asm,
    );

    // The lexer's own functions were emitted (TypeLisp prefixes user symbols
    // with `_tl_`): the scan loop, its token helpers, and the identifier path
    // that builds a `(TIdent text)` token from a `substring` of the source.
    for sym in [
        "_tl_lex:",
        "_tl_token_tag:",
        "_tl_single_token:",
        "_tl_ident_end:",
        "_tl_ident_token:",
        "_tl_ident_text_length:",
    ] {
        assert!(
            asm.contains(sym),
            "lexer assembly is missing expected symbol {}:\n{}",
            sym,
            asm,
        );
    }
}
