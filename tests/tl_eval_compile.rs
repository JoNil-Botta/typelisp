//! Cross-platform proof that the TypeLisp-syntax s-expression *evaluator*
//! (`tests/integration/tl_eval.tl`) compiles all the way to valid x86_64
//! assembly.
//!
//! `tl_eval.tl` is the third piece of TypeLisp's *real* self-hosting compiler
//! front end (#27): a tiny tree-walking interpreter, now with VARIABLES, lexical
//! `let` (now MULTI-BINDING, with sequential `let*` scoping), short-circuit `if`,
//! comparison operators, USER-DEFINED FUNCTIONS plus
//! RECURSION via top-level `(define (f x y z) body)` forms with MULTI-ARGUMENT
//! calls, AND a tagged VALUE domain - `(defenum Value (VInt i64) (VStr String))`
//! - so an expression now denotes a `VInt` or a `VStr` rather than a raw `i64`
//! (integer-requiring contexts funnel through the `as-int` projection). Where the
//! lexer turns a source String into a flat `(Array Token)` and the reader consumes
//! that token stream into the recursive cons-cell `Sexpr` AST `(SInt | SSym | SStr
//! | SNil | SCons)`, the evaluator INTERPRETS that tree WITH RESPECT TO two
//! environments - a value `Env` and a function `FnEnv`: it resolves bare symbols
//! via recursive `lookup`, folds a multi-binding `let` into sequential `EBind`
//! frames, dispatches `if` without evaluating the untaken branch, folds
//! `= < > <= >=` to 1/0 integer truth values, evaluates builtin binary arithmetic,
//! and OTHERWISE treats the head symbol as a CALL into a `FnEnv` assoc-list of
//! `(define ...)`s - looking up the function's PARAMETER LIST and body, ZIPPING
//! the parameter list against the argument expressions with `bind-args` (each
//! argument evaluated in the caller env) to build a fresh callee env, and
//! evaluating the body in that env with the SAME `FnEnv`, so a body can call
//! itself (RECURSION) or any sibling with any arity. A whole PROGRAM is now a
//! sequence of top-level forms - zero or more `(define ...)`s then a trailing
//! expression - read with the reader's lower-level `read-form` cursor API (the
//! plain `read` returns only the first datum). It does NOT
//! re-derive lexing or reading: it `(import)`s the reader's `read-form` and the
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
    // the arity guard, the multi-binding `let` helpers (`let-bindings` projects
    // the binding LIST, `eval-let-bindings` folds it into the env), the
    // `define`-form projections
    // (now `define-params`, returning the whole parameter LIST), the
    // function-environment lookups (`lookup-fn-params` / `lookup-fn-body`), the
    // multi-argument call binder (`bind-args`, which zips params against args),
    // and the multi-form program reader (`run-forms` / `run-program`). The old
    // `sexpr-sym` projection is gone: `eval-sexpr`, `let-var`, and the define
    // projections bind symbol text directly via nested patterns (#41).
    for sym in [
        "_tl_eval_sexpr:",
        "_tl_lookup:",
        "_tl_lookup_fn_params:",
        "_tl_lookup_fn_body:",
        "_tl_bind_args:",
        "_tl_sexpr_head:",
        "_tl_sexpr_tail:",
        "_tl_sexpr_expect_nil:",
        "_tl_let_bindings:",
        "_tl_eval_let_bindings:",
        "_tl_let_var:",
        "_tl_let_init:",
        "_tl_let_body:",
        "_tl_define_name:",
        "_tl_define_params:",
        "_tl_define_body:",
        "_tl_is_define:",
        "_tl_run_forms:",
        "_tl_run_program:",
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

    // MULTI-ARGUMENT (#27): the single-parameter `define-param` projection and the
    // single-parameter `lookup-fn-param` lookup were GENERALISED to the whole
    // parameter LIST (`define-params` / `lookup-fn-params`), so the old
    // single-result symbols must no longer be emitted. (The `:` suffix
    // distinguishes the removed `_tl_define_param:` / `_tl_lookup_fn_param:` labels
    // from the new `_tl_define_params:` / `_tl_lookup_fn_params:` ones.)
    for gone in ["_tl_define_param:", "_tl_lookup_fn_param:"] {
        assert!(
            !asm.contains(gone),
            "tl_eval should no longer define the single-parameter helper {} \
             (generalised to the whole parameter list for multi-argument functions):\n{}",
            gone,
            asm,
        );
    }

    // MULTI-BINDING `let` (#27): the single-binding `let-binding` projection (which
    // forced exactly one binding pair) was GENERALISED to `let-bindings` (the whole
    // binding LIST) plus `eval-let-bindings` (a recursive fold of that list into the
    // env). The old single-binding helper `_tl_let_binding:` (note: no trailing `s`
    // before the `:`) must no longer be emitted.
    assert!(
        !asm.contains("_tl_let_binding:"),
        "tl_eval should no longer define the single-binding let-binding helper \
         (generalised to the binding-list fold for multi-binding let):\n{}",
        asm,
    );

    // The binding LIST is folded into the env by `eval-let-bindings`, which walks
    // the list head-first - evaluating each initializer in the env built so far and
    // recursing on the binding tail. So a call to `eval-let-bindings` AND a
    // recursive self-call within it must both be present (the multi-binding fold).
    assert!(
        asm.contains("call _tl_eval_let_bindings"),
        "tl_eval assembly shows no eval-let-bindings call (no multi-binding let fold):\n{}",
        asm,
    );
    assert!(
        asm.matches("call _tl_eval_let_bindings").count() >= 2,
        "tl_eval assembly shows no recursive eval-let-bindings self-call \
         (binding-list fold):\n{}",
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
    // the imported per-form `read-form` cursor entry, the imported `lex` entry,
    // and the imported `token-str` accessor are emitted. The reader now consumes
    // the lexer's `TStr` token (#128) into the new `(SStr String)` atom via
    // `token-str`, so the accessor crosses the import boundary into the evaluator's
    // program just like `read-form` / `lex` do.
    for sym in ["_tl_read_form:", "_tl_lex:", "_tl_token_str:"] {
        assert!(
            asm.contains(sym),
            "tl_eval assembly is missing expected imported reader/lexer symbol {}:\n{}",
            sym,
            asm,
        );
    }

    // TAGGED VALUE DOMAIN (#27): the value domain is generalised from a raw `i64`
    // to a tagged `(defenum Value (VInt i64) (VStr String))`, so `eval-sexpr`
    // yields a `Value`, the env binds `Value`s, and integer-requiring contexts
    // (operator operands, the `if` condition) funnel through the `as-int`
    // projection. `as-int` must be emitted as its own function, and its
    // type-error abort message must reach the read-only data.
    assert!(
        asm.contains("_tl_as_int:"),
        "tl_eval assembly is missing the as-int projection (tagged Value domain):\n{}",
        asm,
    );
    assert!(
        asm.contains(".string \"type error: expected int\""),
        "tl_eval assembly is missing the as-int type-error message (VStr in int context):\n{}",
        asm,
    );

    // STRING OPERATIONS (#27): the interpreter exposes the host string builtins
    // `string-length` / `substring` / `string-eq` as dispatch arms in
    // `eval-sexpr`, keyed on the head symbol text. Each evaluates its argument
    // sub-exprs, projects them to the host shape (a String via the new `as-str`
    // companion of `as-int`, an i64 via `as-int`), calls the host builtin, and
    // re-wraps the result as a tagged `Value`. So `as-str` must be emitted as its
    // own function, and its type-error abort message (a `VInt` where a string is
    // required) must reach the read-only data.
    assert!(
        asm.contains("_tl_as_str:"),
        "tl_eval assembly is missing the as-str projection (string-op operand unwrap):\n{}",
        asm,
    );
    assert!(
        asm.contains(".string \"type error: expected string\""),
        "tl_eval assembly is missing the as-str type-error message (VInt in string context):\n{}",
        asm,
    );

    // The string ops are dispatched on their head-symbol text, so each op's
    // string literal must be emitted in the read-only data: `"string-length"`
    // (1 arg -> VInt byte count), `"substring"` (3 args -> VStr slice), and
    // `"string-eq"` (2 args -> VInt 1/0). Note `"string-eq"` is ALSO the operator-
    // dispatch builtin's name, but here it is the interpreted-language head symbol
    // the evaluator recognises.
    for op in [
        "\"string-length\"",
        "\"substring\"",
        "\"string-eq\"",
        "\"int->string\"",
        "\"string->int\"",
    ] {
        assert!(
            asm.contains(&format!(".string {op}")),
            "tl_eval assembly is missing the dispatch string literal for the string op {op}:\n{}",
            asm,
        );
    }

    // The `substring` dispatch arm lowers the host `substring` builtin to a call
    // into the emit-on-demand runtime `tl_substring` (a heap-allocated, runtime
    // bounds-checked slice). Its definition and at least one call site must be
    // present. (The imported lexer also slices lexemes with `substring`, so this
    // helper is shared; the evaluator's own string-op arm adds a further call.)
    assert!(
        asm.contains("tl_substring:"),
        "tl_eval assembly is missing the tl_substring runtime helper (substring string op):\n{}",
        asm,
    );
    assert!(
        asm.contains("call tl_substring"),
        "tl_eval assembly shows no substring call (substring string op not lowered):\n{}",
        asm,
    );

    // The `string-length` dispatch arm lowers the host `string-length` builtin.
    // Its byte-count is computed inline (the String's length field) rather than via
    // a dedicated runtime helper, so we assert the dispatch literal (above) plus the
    // `as-str` unwrap (above) cover its wiring; no `tl_string_length:` symbol is
    // required.

    // The `int->string` dispatch arm (1 arg -> VStr) lowers the host `int->string`
    // builtin to a call into the emit-on-demand runtime `tl_int_to_string`, which
    // heap-allocates the decimal-text String of an i64 (so it outlives the frame).
    // Its definition and at least one call site must be present.
    assert!(
        asm.contains("tl_int_to_string:"),
        "tl_eval assembly is missing the tl_int_to_string runtime helper (int->string op):\n{}",
        asm,
    );
    assert!(
        asm.contains("call tl_int_to_string"),
        "tl_eval assembly shows no int->string call (int->string string op not lowered):\n{}",
        asm,
    );

    // The `string->int` dispatch arm (1 arg -> VInt) lowers the host `string->int`
    // builtin to a call into the emit-on-demand runtime `tl_string_to_int`, which
    // parses the decimal string's bytes to an i64. Its definition and at least one
    // call site must be present. (The imported lexer also parses numeric literals
    // with `string->int`, so this helper is shared; the evaluator's own dispatch arm
    // adds a further call.)
    assert!(
        asm.contains("tl_string_to_int:"),
        "tl_eval assembly is missing the tl_string_to_int runtime helper (string->int op):\n{}",
        asm,
    );
    assert!(
        asm.contains("call tl_string_to_int"),
        "tl_eval assembly shows no string->int call (string->int string op not lowered):\n{}",
        asm,
    );

    // EXHAUSTIVE over the SStr variant (#27/#128) AND the value domain (#27): the
    // reader's `(SStr String)` atom now evaluates to a first-class `(VStr s)`
    // VALUE rather than aborting, so the old "eval: strings not supported" panic is
    // GONE. `VStr` PRINTING is now WIRED (#27): the `print` special form's
    // `(VStr s)` arm dispatches to the host `print-string` builtin, which lowers to
    // the emit-on-demand write(2)-syscall runtime helper `tl_print_str` - so the
    // old deferral abort message is GONE and the runtime + a call to it are
    // present.
    assert!(
        !asm.contains("eval: strings not supported"),
        "tl_eval should no longer abort on string literals (SStr now evaluates to VStr):\n{}",
        asm,
    );
    assert!(
        !asm.contains("print: strings not yet printable"),
        "tl_eval should no longer abort on VStr printing (the VStr arm now dispatches \
         to the host print-string builtin):\n{}",
        asm,
    );
    // The `(VStr s)` arm lowers `(print-string s)` to the emit-on-demand
    // `tl_print_str` runtime (writes the string's raw bytes to fd 1 via a write(2)
    // syscall, NO trailing newline), so the runtime's definition AND a call to it
    // must both be present - this is the load-bearing wiring of string output.
    assert!(
        asm.contains("tl_print_str:"),
        "tl_eval assembly is missing the tl_print_str runtime helper (VStr-print wiring):\n{}",
        asm,
    );
    assert!(
        asm.contains("call tl_print_str"),
        "tl_eval assembly shows no host print-string call (the VStr arm must print \
         the string's bytes):\n{}",
        asm,
    );
    // (The host `print` runtime helper `tl_print_i64` and its call site - emitted
    // by the `(print e)` special form's `VInt` arm - are asserted further down,
    // alongside the `"print"` dispatch-string literal.)

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

    // USER FUNCTIONS + RECURSION (#27): a call form whose head is neither a
    // special form nor a builtin is dispatched as a CALL into the function
    // environment. `eval-sexpr` therefore looks the function's PARAMETER LIST and
    // body up in the `FnEnv` via `lookup-fn-params` / `lookup-fn-body`, each of
    // which is itself recursive (it walks the `FnEnv` assoc-list head-first,
    // comparing the bound function name and recursing on the tail). So a call to
    // each lookup AND a recursive self-call within each must be present.
    for fname in ["_tl_lookup_fn_params", "_tl_lookup_fn_body"] {
        assert!(
            asm.contains(&format!("call {fname}")),
            "tl_eval assembly shows no function-environment lookup call ({fname}) - \
             no user-function call dispatch:\n{}",
            asm,
        );
        assert!(
            asm.matches(&format!("call {fname}")).count() >= 2,
            "tl_eval assembly shows no recursive {fname} self-call (FnEnv assoc-list walk):\n{}",
            asm,
        );
    }

    // MULTI-ARGUMENT CALLS (#27): a user-function call binds its arguments by
    // ZIPPING the function's parameter list against the call's argument-expression
    // list with `bind-args`. `bind-args` walks both lists in lock-step, evaluating
    // each argument in the caller env and `EBind`-ing it to the matching parameter,
    // so it is itself recursive (it recurses on the parameter/argument tails) and
    // it calls back into `eval-sexpr` to evaluate each argument. So `eval-sexpr`
    // calls `bind-args`, AND `bind-args` calls itself (a self-call: the recursive
    // zip).
    assert!(
        asm.contains("call _tl_bind_args"),
        "tl_eval assembly shows no bind-args call (no multi-argument call binding):\n{}",
        asm,
    );
    assert!(
        asm.matches("call _tl_bind_args").count() >= 2,
        "tl_eval assembly shows no recursive bind-args self-call (param/arg zip):\n{}",
        asm,
    );

    // The program is a SEQUENCE of top-level forms read with the reader's
    // lower-level per-form cursor API, so `run-forms` reuses `read-form` and is
    // itself recursive - it reads one form, folds a `(define ...)` into the
    // `FnEnv`, and recurses for the rest until the trailing expression. A
    // `run-forms` self-call must therefore be present.
    assert!(
        asm.matches("call _tl_run_forms").count() >= 1,
        "tl_eval assembly shows no recursive run-forms self-call (multi-form program reader):\n{}",
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

    // CONDITIONALS (#27): the `if` special form and the comparison operators are
    // dispatched on their operator text, so each operator's string literal must
    // be emitted in the read-only data. `"if"` selects the short-circuit special
    // form; `"<"`/`">"`/`"<="`/`">="` (and the existing `"="`) are the comparison
    // operators that fold their bool result to the 1/0 integer-truth convention.
    for op in ["\"if\"", "\"=\"", "\"<\"", "\">\"", "\"<=\"", "\">=\""] {
        assert!(
            asm.contains(&format!(".string {op}")),
            "tl_eval assembly is missing the dispatch string literal for operator {op} \
             (conditionals/comparisons):\n{}",
            asm,
        );
    }

    // USER FUNCTIONS (#27): the program reader splits top-level forms on the
    // `define` keyword, so `is-define` compares the head symbol against the
    // `"define"` string literal, which must be emitted in the read-only data.
    assert!(
        asm.contains(".string \"define\""),
        "tl_eval assembly is missing the \"define\" keyword literal (top-level definitions):\n{}",
        asm,
    );

    // PRINTING (#27): the interpreter now has OUTPUT. `eval-sexpr` dispatches a
    // `(print e)` SPECIAL FORM on the head symbol text `"print"`, so that string
    // literal must be emitted in the read-only data alongside the other special
    // forms.
    assert!(
        asm.contains(".string \"print\""),
        "tl_eval assembly is missing the \"print\" dispatch string literal (print special form):\n{}",
        asm,
    );

    // Both the `(print e)` special form AND `main`'s final-result print lower the
    // host `print` builtin to a call into the runtime `tl_print_i64` helper (which
    // writes the full integer + a newline to stdout - escaping the mod-256
    // exit-code ceiling). Its definition and at least one call site must be
    // present.
    assert!(
        asm.contains("tl_print_i64:"),
        "tl_eval assembly is missing the tl_print_i64 runtime helper (host print builtin):\n{}",
        asm,
    );
    assert!(
        asm.contains("call tl_print_i64"),
        "tl_eval assembly shows no host print call (no integer output):\n{}",
        asm,
    );

    // 1024 is the printed integer witness: `main` evaluates a multi-binding `let`
    // whose last binding computes `(pow b e) => 1024`, then prints `r` after first
    // printing a string. The literal `1024` is built by the interpreter's
    // arithmetic at RUNTIME (not a compile-time constant in this evaluator's own
    // source), so we do NOT assert it appears in the assembly; the printed stdout
    // is asserted by the Linux-gated exec test in `tests/integration.rs`.

    // The comparison operators fold a bool to the 1/0 integer-truth convention,
    // so the lowered evaluator must contain at least one signed integer comparison
    // (cmp + a set/conditional-move or conditional jump). `cmp` proves the
    // comparison operators actually emit a magnitude test rather than only the
    // byte-wise `string-eq` used for operator dispatch.
    assert!(
        asm.contains("cmp"),
        "tl_eval assembly has no integer comparison (cmp) for the comparison operators:\n{}",
        asm,
    );

    // `main` drives the whole composed pipeline through `run-program`: lex the
    // whole source, read EVERY top-level form with the reader's per-form cursor
    // API, then interpret the trailing expression - so the lexing entry, the
    // per-form reader entry, and the evaluator are all called.
    assert!(
        asm.contains("call _tl_lex"),
        "tl_eval assembly shows no lex call (lexing step reused):\n{}",
        asm,
    );
    assert!(
        asm.contains("call _tl_read_form"),
        "tl_eval assembly shows no read-form call (per-form reading step reused):\n{}",
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
