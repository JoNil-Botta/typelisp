//! Cross-platform proof that the TypeLisp-syntax s-expression *reader*
//! (`tests/integration/tl_reader.tl`) compiles all the way to valid x86_64
//! assembly.
//!
//! `tl_reader.tl` is the second piece of TypeLisp's *real* self-hosting compiler
//! front end (#27): the canonical Lisp reader. Where the lexer turns a source
//! String into a flat `(Array Token)`, the reader consumes that token stream
//! into the recursive cons-cell tree the parens describe - the `Sexpr` AST
//! `(SInt | SSym | SNil | SCons)`. It does NOT re-derive tokenization: it
//! `(import)`s the lexer's `lex` from the `main`-less module `tl_lex.tl`, which
//! itself imports the `main`-less token model `tl_token.tl`. So compiling it
//! also exercises the module loader (#44) transitively: `tl_token.tl` and
//! `tl_lex.tl` are loaded (imported-before-importer) and concatenated with this
//! file, and because NEITHER imported module declares a `main`, the combined
//! program has exactly one `main` - the reader's - with no duplicate-symbol
//! clash. (Importing the `main`-bearing `tl_lexer.tl` demo would have clashed;
//! the reusable lexer lives in the `main`-less `tl_lex.tl` precisely to avoid
//! that.)
//!
//! Like the other `*_compile.rs` tests this only invokes the `compile`
//! subcommand, so it runs everywhere - including the Windows dev box - and
//! asserts on the emitted assembly text. The assemble+link+run check is
//! Linux-gated in `tests/integration.rs`.

use std::fs;
use std::path::PathBuf;
use std::process::Command;

#[test]
fn tl_reader_tl_compiles_to_assembly() {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let integration_dir = manifest_dir.join("tests").join("integration");
    let source_path = integration_dir.join("tl_reader.tl");

    let work_dir = manifest_dir.join("target").join("tl-reader-compile-test");
    fs::create_dir_all(&work_dir).expect("create tl_reader compile test work dir");

    // The reader imports `tl_lex.tl`, which transitively imports `tl_token.tl`.
    // The loader resolves imports relative to the importing file, so both
    // imported modules must sit alongside the entry file in the work dir for the
    // `(import ...)` chain to resolve.
    let entry_path = work_dir.join("tl_reader.tl");
    fs::copy(&source_path, &entry_path).expect("copy tl_reader.tl to work dir");
    for dep in ["tl_lex.tl", "tl_token.tl"] {
        fs::copy(integration_dir.join(dep), work_dir.join(dep))
            .unwrap_or_else(|e| panic!("copy imported module {dep}: {e}"));
    }

    let asm_path = work_dir.join("tl_reader.s");

    let output = Command::new(env!("CARGO_BIN_EXE_typelisp"))
        .arg("compile")
        .arg(&entry_path)
        .arg("-o")
        .arg(&asm_path)
        .output()
        .expect("run typelisp compile");

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        output.status.success(),
        "tl_reader.tl compile step failed\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr,
    );

    let asm = fs::read_to_string(&asm_path).expect("read generated tl_reader assembly");

    // The whole reader lowered: no stubbed-out / unimplemented constructs.
    assert!(
        !asm.contains("# TODO"),
        "tl_reader assembly still contains a # TODO marker:\n{}",
        asm,
    );

    // Multi-file organization (#44): the imported `main`-less `tl_lex.tl` and
    // `tl_token.tl` contribute `lex` / `Token` / accessors but no `main`, so the
    // concatenated program has EXACTLY one `main:` - the reader's. The import
    // chain composes with no duplicate-symbol clash.
    assert_eq!(
        asm.matches("\nmain:").count() + usize::from(asm.starts_with("main:")),
        1,
        "tl_reader assembly must have exactly one main: (imports must not duplicate symbols):\n{}",
        asm,
    );

    // The token array and every heap-promoted `Sexpr` / `Token` / String payload
    // are allocated through the runtime allocator. `SCons` carries two `Sexpr`
    // children (8-byte heap pointers each, #111), so building the cons tree
    // allocates a node per `SCons`/`SInt`/`SSym`.
    assert!(
        asm.contains("call tl_alloc"),
        "tl_reader assembly does not heap-allocate its Sexpr/token nodes via tl_alloc:\n{}",
        asm,
    );

    // The reader's own functions were emitted (TypeLisp prefixes user symbols
    // with `_tl_`): the public `read` entry, the mutually recursive `read-form`
    // / `read-list`, and the `sum-ints` fold over the built tree.
    for sym in [
        "_tl_read:",
        "_tl_read_form:",
        "_tl_read_list:",
        "_tl_sum_ints:",
    ] {
        assert!(
            asm.contains(sym),
            "tl_reader assembly is missing expected reader symbol {}:\n{}",
            sym,
            asm,
        );
    }

    // The lexer is REUSED across the import boundary, not re-derived: the
    // imported `lex` entry and the imported `tl_token.tl` accessors are emitted
    // and called. `token-tag` classifies each token under the cursor.
    for sym in [
        "_tl_lex:",
        "_tl_token_tag:",
        "_tl_token_int:",
        "_tl_token_sym:",
    ] {
        assert!(
            asm.contains(sym),
            "tl_reader assembly is missing expected imported lexer/token symbol {}:\n{}",
            sym,
            asm,
        );
    }

    // `main` drives the whole pipeline: lex the sample, read it into the Sexpr
    // tree, then fold the tree - so the lexing entry, the reader entry, and the
    // fold are all called.
    assert!(
        asm.contains("call _tl_lex"),
        "tl_reader assembly shows no main -> lex call (lexing step reused):\n{}",
        asm,
    );
    assert!(
        asm.contains("call _tl_read"),
        "tl_reader assembly shows no main -> read call (reading step):\n{}",
        asm,
    );
    assert!(
        asm.contains("call _tl_sum_ints"),
        "tl_reader assembly shows no main -> sum-ints call (tree fold):\n{}",
        asm,
    );

    // read-form and read-list are mutually recursive: read-form descends into a
    // list via read-list, and read-list reads each element via read-form and
    // recurses for the tail. Both call edges must be present.
    assert!(
        asm.contains("call _tl_read_list"),
        "tl_reader assembly shows no read-form -> read-list descent:\n{}",
        asm,
    );
    assert!(
        asm.contains("call _tl_read_form"),
        "tl_reader assembly shows no read-list -> read-form element read:\n{}",
        asm,
    );

    // A token under the cursor is classified through the imported `token-tag`
    // accessor - the cross-import call that drives the reader's descent.
    assert!(
        asm.contains("call _tl_token_tag"),
        "tl_reader assembly shows no token-tag classification call:\n{}",
        asm,
    );

    // Malformed input (a stray ')', a premature end, or an unterminated list)
    // aborts via `(panic ...)`, lowered to the private abort runtime - exactly
    // how a real reader reports a syntax error.
    assert!(
        asm.contains("call .L_tl_abort"),
        "tl_reader assembly is missing the reader-error abort path (.L_tl_abort):\n{}",
        asm,
    );
}
