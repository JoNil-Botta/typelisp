//! Cross-platform proof that the TypeLisp-syntax s-expression *evaluator*
//! (`tests/integration/tl_eval.tl`) compiles all the way to valid x86_64
//! assembly.
//!
//! `tl_eval.tl` is the third piece of TypeLisp's *real* self-hosting compiler
//! front end (#27): a tiny tree-walking interpreter, now with VARIABLES and a
//! `let` special form threaded through a lexical environment. Where the lexer
//! turns a source String into a flat `(Array Token)` and the reader consumes that
//! token stream into the recursive cons-cell `Sexpr` AST `(SInt | SSym | SNil |
//! SCons)`, the evaluator INTERPRETS that tree WITH RESPECT TO an environment - it
//! walks the s-expression, dispatches on the head symbol, resolves a bare symbol
//! as a variable reference via `lookup` over the cons-cell assoc-list `Env`
//! (`ENil | (EBind String i64 Env)`), handles `(let ((x e1)) body)` by pushing an
//! `EBind` frame, and otherwise recursively evaluates the argument sub-exprs and
//! computes the integer the expression denotes. It does NOT
//! re-derive lexing or reading: it `(import)`s the reader's `read` and the
//! `Sexpr` enum from the `main`-less module `tl_read.tl`, which itself imports
//! the `main`-less lexer `tl_lex.tl`, which imports the `main`-less token model
//! `tl_token.tl`. So compiling it exercises the module loader (#44) transitively:
//! `tl_token.tl`, `tl_lex.tl`, and `tl_read.tl` are loaded
//! (imported-before-importer) and concatenated with this file, and because NONE
//! of the imported modules declares a `main`, the combined program has exactly
//! one `main` - the evaluator's - with no duplicate-symbol clash. (Importing the
//! `main`-bearing `tl_reader.tl` demo would have clashed; the reusable reader
//! lives in the `main`-less `tl_read.tl` precisely to avoid that.)
//!
//! Like the other `*_compile.rs` tests this only invokes the `compile`
//! subcommand, so it runs everywhere - including the Windows dev box - and
//! asserts on the emitted assembly text. The assemble+link+run check is
//! Linux-gated in `tests/integration.rs`.

use std::fs;
use std::path::PathBuf;
use std::process::Command;

#[test]
fn tl_eval_tl_compiles_to_assembly() {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let integration_dir = manifest_dir.join("tests").join("integration");
    let source_path = integration_dir.join("tl_eval.tl");

    let work_dir = manifest_dir.join("target").join("tl-eval-compile-test");
    fs::create_dir_all(&work_dir).expect("create tl_eval compile test work dir");

    // The evaluator imports `tl_read.tl`, which imports `tl_lex.tl`, which
    // transitively imports `tl_token.tl`. The loader resolves imports relative to
    // the importing file, so every imported module must sit alongside the entry
    // file in the work dir for the `(import ...)` chain to resolve.
    let entry_path = work_dir.join("tl_eval.tl");
    fs::copy(&source_path, &entry_path).expect("copy tl_eval.tl to work dir");
    for dep in ["tl_read.tl", "tl_lex.tl", "tl_token.tl"] {
        fs::copy(integration_dir.join(dep), work_dir.join(dep))
            .unwrap_or_else(|e| panic!("copy imported module {dep}: {e}"));
    }

    let asm_path = work_dir.join("tl_eval.s");

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
        "tl_eval.tl compile step failed\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr,
    );

    let asm = fs::read_to_string(&asm_path).expect("read generated tl_eval assembly");

    // The whole evaluator lowered: no stubbed-out / unimplemented constructs.
    assert!(
        !asm.contains("# TODO"),
        "tl_eval assembly still contains a # TODO marker:\n{}",
        asm,
    );

    // Multi-file organization (#44): the imported `main`-less `tl_read.tl`,
    // `tl_lex.tl`, and `tl_token.tl` contribute `read` / `lex` / `Sexpr` / `Token`
    // + accessors but no `main`, so the concatenated program has EXACTLY one
    // `main:` - the evaluator's. The import chain composes with no
    // duplicate-symbol clash.
    assert_eq!(
        asm.matches("\nmain:").count() + usize::from(asm.starts_with("main:")),
        1,
        "tl_eval assembly must have exactly one main: (imports must not duplicate symbols):\n{}",
        asm,
    );

    // Every heap-promoted `Sexpr` / `Token` / String payload is allocated through
    // the runtime allocator: building the cons tree allocates a node per
    // `SCons`/`SInt`/`SSym` (#111).
    assert!(
        asm.contains("call tl_alloc"),
        "tl_eval assembly does not heap-allocate its Sexpr/token nodes via tl_alloc:\n{}",
        asm,
    );

    // The evaluator's own functions were emitted (TypeLisp prefixes user symbols
    // with `_tl_`): the tree-walking `eval-sexpr`, recursive variable `lookup`,
    // the cons-cell projections `sexpr-head` ("car") / `sexpr-tail` ("cdr"),
    // the arity guard, and the `let`-binding helpers. The old `sexpr-sym`
    // projection is gone: `eval-sexpr` and `let-var` bind symbol text directly
    // via nested patterns (#41).
    for sym in [
        "_tl_eval_sexpr:",
        "_tl_lookup:",
        "_tl_sexpr_head:",
        "_tl_sexpr_tail:",
        "_tl_sexpr_expect_nil:",
        "_tl_let_binding:",
        "_tl_let_var:",
        "_tl_let_init:",
        "_tl_let_body:",
    ] {
        assert!(
            asm.contains(sym),
            "tl_eval assembly is missing expected evaluator symbol {}:\n{}",
            sym,
            asm,
        );
    }

    // The `sexpr-sym` projection helper was REMOVED in favour of the nested
    // pattern; it must no longer be emitted.
    assert!(
        !asm.contains("_tl_sexpr_sym:"),
        "tl_eval should no longer define the sexpr-sym projection (replaced by a \
         nested pattern):\n{}",
        asm,
    );

    // The nested pattern `(SCons (SSym name) rest)` lowers to a SECOND tag
    // dispatch inside the SCons arm (testing the inner SSym tag), labelled
    // `match_nested` by the lowerer (#41). Its presence proves the operator
    // symbol is destructured in the `match` itself rather than by a helper.
    assert!(
        asm.contains("match_nested"),
        "tl_eval assembly has no nested tag-dispatch block (match_nested) for the \
         `(SCons (SSym name) rest)` pattern:\n{}",
        asm,
    );

    // The reader and lexer are REUSED across the import boundary, not re-derived:
    // the imported `read` entry and the imported `lex` entry are emitted.
    for sym in ["_tl_read:", "_tl_lex:"] {
        assert!(
            asm.contains(sym),
            "tl_eval assembly is missing expected imported reader/lexer symbol {}:\n{}",
            sym,
            asm,
        );
    }

    // `eval-sexpr` is genuinely recursive: it evaluates each argument sub-expr by
    // calling itself, so the result depends on the whole nested tree shape.
    assert!(
        asm.contains("call _tl_eval_sexpr"),
        "tl_eval assembly shows no recursive eval-sexpr self-call (tree walk):\n{}",
        asm,
    );

    // Variables: a bare symbol is resolved as a variable reference, and `let`
    // binds a name into the environment. `eval-sexpr` therefore calls `lookup`,
    // and `lookup` is itself recursive - it walks the `Env` assoc-list chain
    // head-first, comparing each bound name to the query and recursing on the
    // tail. So a `lookup` call AND a `lookup` self-call must both be present.
    assert!(
        asm.contains("call _tl_lookup"),
        "tl_eval assembly shows no variable-lookup call (no environment threading):\n{}",
        asm,
    );
    assert!(
        asm.matches("call _tl_lookup").count() >= 2,
        "tl_eval assembly shows no recursive lookup self-call (assoc-list walk):\n{}",
        asm,
    );

    // Operator dispatch is by byte-wise string equality: the head symbol text is
    // compared against "+"/"-"/"*"/"/" via the emit-on-demand `tl_string_eq`
    // runtime helper. Its definition and at least one call must be present.
    assert!(
        asm.contains("tl_string_eq:"),
        "tl_eval assembly is missing the tl_string_eq runtime helper (operator dispatch):\n{}",
        asm,
    );
    assert!(
        asm.contains("call tl_string_eq"),
        "tl_eval assembly shows no string-eq operator-dispatch call:\n{}",
        asm,
    );

    // `main` drives the whole composed pipeline: lex the sample, read it into the
    // Sexpr tree, then interpret it - so the lexing entry, the reader entry, and
    // the evaluator are all called.
    assert!(
        asm.contains("call _tl_lex"),
        "tl_eval assembly shows no main -> lex call (lexing step reused):\n{}",
        asm,
    );
    assert!(
        asm.contains("call _tl_read"),
        "tl_eval assembly shows no main -> read call (reading step reused):\n{}",
        asm,
    );

    // A malformed program (a non-symbol operator, too few/many arguments, or an
    // unknown operator) aborts via `(panic ...)`, lowered to the private abort runtime -
    // exactly how a real interpreter reports a malformed program.
    assert!(
        asm.contains("call .L_tl_abort"),
        "tl_eval assembly is missing the eval-error abort path (.L_tl_abort):\n{}",
        asm,
    );
}
