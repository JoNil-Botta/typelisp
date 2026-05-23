//! Cross-platform proof that the TypeLisp-syntax lexer
//! (`selfhost/lexer.tl`) compiles all the way to valid x86_64
//! assembly.
//!
//! `lexer.tl` is the first piece of TypeLisp's *real* self-hosting compiler
//! front end (#27): a tokenizer for the s-expression syntax TypeLisp source is
//! actually written in - balanced parens, integer literals, and *symbols*
//! (operators / keywords / names are all one `TSym` kind) - NOT the
//! arithmetic-calculator surface that `lexer.tl` / `calc.tl` tokenize. It
//! `(import)`s the `main`-less token model `token.tl`, so compiling it also
//! exercises the module loader (#44): the import is resolved relative to
//! `lexer.tl`, the co-located `token.tl` is loaded, and its declarations
//! are concatenated into one program.
//!
//! Like the other `*_compile.rs` tests this only invokes the `compile`
//! subcommand, so it runs everywhere - including the Windows dev box - and
//! asserts on the emitted assembly text. The assemble+link+run check is
//! Linux-gated in `tests/integration.rs`.

use std::fs;
use std::path::PathBuf;
use std::process::Command;

#[test]
fn tl_lexer_tl_compiles_to_assembly() {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let source_path = manifest_dir.join("selfhost").join("lexer.tl");

    let work_dir = manifest_dir.join("target").join("tl-lexer-compile-test");
    fs::create_dir_all(&work_dir).expect("create tl_lexer compile test work dir");
    let asm_path = work_dir.join("tl_lexer.s");

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

    let asm = fs::read_to_string(&asm_path).expect("read generated tl_lexer assembly");

    // The whole lexer lowered: no stubbed-out / unimplemented constructs.
    assert!(
        !asm.contains("# TODO"),
        "tl_lexer assembly still contains a # TODO marker:\n{}",
        asm,
    );

    // Multi-file organization (#44): the imported `main`-less `token.tl`
    // contributes its `Token`/accessors but no `main`, so the concatenated
    // program has EXACTLY one `main:` - the import composes with no
    // duplicate-symbol clash.
    assert_eq!(
        asm.matches("\nmain:").count() + usize::from(asm.starts_with("main:")),
        1,
        "tl_lexer assembly must have exactly one main: (import must not duplicate symbols):\n{}",
        asm,
    );

    // The token array and every String/`Token` payload are heap-allocated
    // through the runtime allocator (the token array, the substring-sliced
    // symbol lexemes, and the heap-promoted `TSym`/`TInt` payloads).
    assert!(
        asm.contains("call tl_alloc"),
        "tl_lexer assembly does not allocate its token array / token payloads via tl_alloc:\n{}",
        asm,
    );

    // A symbol/integer lexeme is sliced out of the source String with
    // `substring`, lowered to the `tl_substring` runtime helper.
    assert!(
        asm.contains("call tl_substring"),
        "tl_lexer assembly does not slice lexemes via tl_substring:\n{}",
        asm,
    );

    // An integer literal's digit-run substring is parsed with `string->int`,
    // lowered to the `tl_string_to_int` runtime helper - the lexer's numeric
    // primitive.
    assert!(
        asm.contains("call tl_string_to_int"),
        "tl_lexer assembly does not parse integer literals via tl_string_to_int:\n{}",
        asm,
    );

    // String indexing and array bounds are checked: `string-ref` and the token
    // array reads/writes go through the out-of-bounds abort helper.
    assert!(
        asm.contains("call tl_oob_abort"),
        "tl_lexer assembly is missing the bounds-check trap (tl_oob_abort):\n{}",
        asm,
    );

    // The unexpected-character path lowers `(panic ...)` to the private abort
    // runtime, exactly as a real lexer reports malformed input.
    assert!(
        asm.contains("call .L_tl_abort"),
        "tl_lexer assembly is missing the panic/lex-error abort path (.L_tl_abort):\n{}",
        asm,
    );

    // The lexer's functions were emitted (TypeLisp prefixes user symbols with
    // `_tl_`): the public `lex` entry, the scan-into loop, the int/symbol run
    // scanners, the string-literal / char-literal / line-comment scanners, the
    // TSym / TStr / TChar / total-token tallies, and the imported token
    // accessors `token.tl` contributes across the import boundary.
    for sym in [
        "_tl_lex:",
        "_tl_lex_into:",
        "_tl_scan_int_end:",
        "_tl_scan_symbol_end:",
        "_tl_scan_str_end:",
        "_tl_scan_comment_end:",
        "_tl_starts_named_char:",
        "_tl_scan_char_name_end:",
        "_tl_require_char_close:",
        "_tl_named_char:",
        "_tl_escaped_char:",
        "_tl_char_literal_value:",
        "_tl_char_literal_end:",
        "_tl_count_syms:",
        "_tl_count_strs:",
        "_tl_count_chars:",
        "_tl_count_tokens:",
        "_tl_token_tag:",
        "_tl_token_int:",
        "_tl_token_sym:",
        "_tl_token_str:",
        "_tl_token_char:",
    ] {
        assert!(
            asm.contains(sym),
            "tl_lexer assembly is missing expected symbol {}:\n{}",
            sym,
            asm,
        );
    }

    // `main` drives the lexer: it lexes the sample then tallies total tokens,
    // TStrs, and TChars, so the lexing entry and all tally helpers are called.
    assert!(
        asm.contains("call _tl_lex"),
        "tl_lexer assembly shows no main -> lex call (lexing step):\n{}",
        asm,
    );
    assert!(
        asm.contains("call _tl_count_tokens"),
        "tl_lexer assembly shows no main -> count-tokens call (total tally):\n{}",
        asm,
    );
    assert!(
        asm.contains("call _tl_count_strs"),
        "tl_lexer assembly shows no main -> count-strs call (string-literal tally):\n{}",
        asm,
    );
    assert!(
        asm.contains("call _tl_count_chars"),
        "tl_lexer assembly shows no main -> count-chars call (char-literal tally):\n{}",
        asm,
    );

    // The TSym String payload is projected back out of a token via the imported
    // `token-tag` accessor while tallying - the import's `match` arms compose
    // with the importer's lexing loop.
    assert!(
        asm.contains("call _tl_token_tag"),
        "tl_lexer assembly shows no token-tag classification call:\n{}",
        asm,
    );
}
