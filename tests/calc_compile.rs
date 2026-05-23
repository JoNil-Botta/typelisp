//! Cross-platform proof that the end-to-end calculator
//! (`tests/integration/calc.tl`) compiles all the way to valid x86_64 assembly.
//!
//! `calc.tl` is the capstone of the self-hosting front-end slice (#27, phase 4):
//! it wires the tokenizer (`lexer.tl`) and the recursive-descent parser
//! (`parser.tl`) into ONE pipeline,
//!
//!   String --lex--> (Array Token) --parse--> Expr --eval--> i64
//!
//! so the whole front end composes. The parser reads tokens straight out of the
//! lexer's real `(Array Token)` (no hand-built token stream), and a recursive
//! tree-walking `eval` folds the `Expr` AST. `main` runs
//! `(eval (parse (lex "2 + 3 * 4")))` and returns 14.
//!
//! Like `lexer_compile.rs` / `parser_compile.rs`, this test only invokes the
//! `compile` subcommand, so it runs everywhere — including the Windows dev box —
//! and asserts on the emitted assembly text. The assemble+link+run check is
//! Linux-gated in `tests/integration.rs`.

use std::fs;
use std::path::PathBuf;
use std::process::Command;

#[test]
fn calc_tl_compiles_to_assembly() {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let source_path = manifest_dir
        .join("tests")
        .join("integration")
        .join("calc.tl");

    let work_dir = manifest_dir.join("target").join("calc-compile-test");
    fs::create_dir_all(&work_dir).expect("create calc compile test work dir");
    let asm_path = work_dir.join("calc.s");

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
        "calc.tl compile step failed\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr,
    );

    let asm = fs::read_to_string(&asm_path).expect("read generated calc assembly");

    // The whole front end lowered: no stubbed-out / unimplemented constructs.
    assert!(
        !asm.contains("# TODO"),
        "calc assembly still contains a # TODO marker:\n{}",
        asm,
    );

    // A real program entry point exists.
    assert!(asm.contains("main:"), "calc assembly has no main:\n{}", asm);

    // The token array, the cursor cell, and every `Expr` AST node are
    // heap-allocated through the runtime allocator (recursive enum payloads are
    // heap-pointer indirections, so each `ENum`/`EAdd`/... constructor allocates).
    assert!(
        asm.contains("call tl_alloc"),
        "calc assembly does not allocate its token array / AST nodes via tl_alloc:\n{}",
        asm,
    );

    // String indexing and array bounds are checked: `string-ref` and the cursor
    // reads/writes go through the out-of-bounds abort helper.
    assert!(
        asm.contains("call tl_oob_abort"),
        "calc assembly is missing the bounds-check trap (tl_oob_abort):\n{}",
        asm,
    );

    // Both error paths lower `(panic ...)` to the private abort runtime: the
    // lexer's unexpected-character path and the parser's `expect`/unexpected-token
    // path.
    assert!(
        asm.contains("call .L_tl_abort"),
        "calc assembly is missing the panic/syntax-error abort path (.L_tl_abort):\n{}",
        asm,
    );

    // The full pipeline's functions were emitted (TypeLisp prefixes user symbols
    // with `_tl_`): the lexer scan loop, the recursive-descent core
    // (`parse_expr`/`parse_term`/`parse_factor`), the `parse` entry that threads
    // the cursor, the token-cursor helpers, and the recursive tree-walking
    // `eval`.
    for sym in [
        "_tl_lex:",
        "_tl_parse:",
        "_tl_parse_expr:",
        "_tl_parse_term:",
        "_tl_parse_factor:",
        "_tl_expect:",
        "_tl_advance:",
        "_tl_eval:",
        "_tl_token_tag:",
        "_tl_token_int:",
    ] {
        assert!(
            asm.contains(sym),
            "calc assembly is missing expected symbol {}:\n{}",
            sym,
            asm,
        );
    }

    // The pipeline composes in `main`: it lexes the source, then feeds the
    // produced token array into `parse`, whose tree it hands to `eval`.
    assert!(
        asm.contains("call _tl_lex"),
        "calc assembly shows no main -> lex call (lexing step):\n{}",
        asm,
    );
    assert!(
        asm.contains("call _tl_parse"),
        "calc assembly shows no main -> parse call (parsing step):\n{}",
        asm,
    );

    // Mutual recursion in the recursive-descent core: a parenthesized factor
    // re-enters `parse_expr`, and the precedence levels chain
    // `parse_expr` -> `parse_term` -> `parse_factor`.
    assert!(
        asm.contains("call _tl_parse_expr"),
        "calc assembly shows no re-entrant parse_expr call (parenthesized factor):\n{}",
        asm,
    );
    assert!(
        asm.contains("call _tl_parse_term"),
        "calc assembly shows no parse_expr -> parse_term call:\n{}",
        asm,
    );
    assert!(
        asm.contains("call _tl_parse_factor"),
        "calc assembly shows no parse_term -> parse_factor call:\n{}",
        asm,
    );

    // The evaluator is a real recursive tree walk: `eval` calls itself on the
    // binary-node children, proving the recursive `Expr` AST folds correctly.
    assert!(
        asm.contains("call _tl_eval"),
        "calc assembly shows no recursive eval -> eval call:\n{}",
        asm,
    );
}
