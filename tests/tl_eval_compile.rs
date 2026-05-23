//! Cross-platform proof that the TypeLisp-syntax s-expression *evaluator*
//! (`selfhost/eval.tl`) compiles all the way to valid x86_64
//! assembly.
//!
//! `eval.tl` is the third piece of TypeLisp's *real* self-hosting compiler
//! front end (#27): a tiny tree-walking interpreter, now with VARIABLES, lexical
//! `let` (now MULTI-BINDING, with sequential `let*` scoping), short-circuit `if`,
//! comparison operators, a `begin` SEQUENCING special form (evaluate a sequence
//! of forms in order, return the last value - the natural sequencing primitive,
//! retiring the old `seq` two-arg-function workaround), USER-DEFINED FUNCTIONS plus
//! RECURSION via top-level `(define (f x y z) body)` forms with MULTI-ARGUMENT
//! calls, FIRST-CLASS FUNCTIONS - `lambda` and CLOSURES, the `(VClosure params
//! body captured-env)` value, CONS PAIRS / LINKED LISTS - `(VPair Value Value)`
//! cells built by `cons` and projected by `car` / `cdr`, also built in one form by
//! the VARIADIC `(list e1 ... en)` SPECIAL FORM (a right-nested cons chain
//! terminated by the `(VInt 0)` NIL sentinel) - the `pair?` / `null?`
//! LIST PREDICATES that let an interpreted program write RECURSIVE LIST ALGORITHMS
//! (`(pair? x)` true iff `x` is a `(VPair ...)`, `(null? x)` true iff `x` is the
//! nil sentinel `(VInt 0)`, refs #141) - AND a tagged VALUE
//! domain - `(defenum Value (VInt i64) (VStr String) (VClosure Sexpr Sexpr Env)
//! (VPair Value Value))` - so an expression now denotes a `VInt`, a `VStr`, a
//! closure, or a pair rather than a raw `i64` (integer-requiring
//! contexts funnel through the `as-int` projection; `Value` and `Env` are mutually
//! recursive enums, the `VClosure` carrying the env it captured). Where the
//! lexer turns a source String into a flat `(Array Token)` and the reader consumes
//! that token stream into the recursive cons-cell `Sexpr` AST `(SInt | SSym | SStr
//! | SChar | SNil | SCons)`, the evaluator INTERPRETS that tree WITH RESPECT TO two
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
//! `Sexpr` enum from the `main`-less module `read.tl`, which itself imports
//! the `main`-less lexer `lex.tl`, which imports the `main`-less token model
//! `token.tl`. So compiling it exercises the module loader (#44) transitively:
//! `token.tl`, `lex.tl`, and `read.tl` are loaded
//! (imported-before-importer) and concatenated with this file, and because NONE
//! of the imported modules declares a `main`, the combined program has exactly
//! one `main` - the evaluator's - with no duplicate-symbol clash. (Importing the
//! `main`-bearing `reader.tl` demo would have clashed; the reusable reader
//! lives in the `main`-less `read.tl` precisely to avoid that.)
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
    let selfhost_dir = manifest_dir.join("selfhost");
    let source_path = selfhost_dir.join("eval.tl");

    let work_dir = manifest_dir.join("target").join("tl-eval-compile-test");
    fs::create_dir_all(&work_dir).expect("create tl_eval compile test work dir");

    // The evaluator imports `read.tl`, which imports `lex.tl`, which
    // transitively imports `token.tl`. The loader resolves imports relative to
    // the importing file, so every imported module must sit alongside the entry
    // file in the work dir for the `(import ...)` chain to resolve.
    let entry_path = work_dir.join("eval.tl");
    fs::copy(&source_path, &entry_path).expect("copy eval.tl to work dir");
    for dep in ["read.tl", "lex.tl", "token.tl"] {
        fs::copy(selfhost_dir.join(dep), work_dir.join(dep))
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
        "eval.tl compile step failed\nstdout:\n{}\nstderr:\n{}",
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

    // Multi-file organization (#44): the imported `main`-less `read.tl`,
    // `lex.tl`, and `token.tl` contribute `read` / `lex` / `Sexpr` / `Token`
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
        "_tl_eval_seq:",
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

    // FIRST-CLASS FUNCTIONS - `lambda` + CLOSURES (#27): the value domain gains a
    // `(VClosure params body captured-env)` variant, so the `lambda` special form
    // is dispatched on the head-symbol text `"lambda"` (which must reach the
    // read-only data) and APPLICATION is handled by `apply-value` (applies a
    // `VClosure` to its arguments). A symbol-head call routes through `env-has`
    // (is the head a closure-valued variable, applied via `apply-value`, or a
    // top-level `define`, called through the `fenv`?), and the closure's
    // parameters are layered over its CAPTURED env by the generalised
    // `bind-args-onto` (the `bind-args` zip now extends a caller-supplied base
    // env). The `lambda` form's parameter list and body are projected by
    // `lambda-params` / `lambda-body`. Each of these helpers must be emitted.
    assert!(
        asm.contains(".string \"lambda\""),
        "tl_eval assembly is missing the \"lambda\" dispatch string literal (lambda special form):\n{}",
        asm,
    );
    for sym in [
        "_tl_apply_value:",
        "_tl_env_has:",
        "_tl_bind_args_onto:",
        "_tl_lambda_params:",
        "_tl_lambda_body:",
    ] {
        assert!(
            asm.contains(sym),
            "tl_eval assembly is missing expected lambda/closure symbol {}:\n{}",
            sym,
            asm,
        );
    }

    // Closure APPLICATION is genuinely wired: `eval-sexpr` calls `apply-value`
    // (both for a computed-operator application `((lambda ...) a)` and for a
    // closure-valued variable in head position), and `apply-value` re-enters
    // `eval-sexpr` to evaluate the closure body. So a call to `apply-value` must
    // be present, and `apply-value` must build the call env via `bind-args-onto`.
    assert!(
        asm.contains("call _tl_apply_value"),
        "tl_eval assembly shows no apply-value call (closure application not wired):\n{}",
        asm,
    );
    assert!(
        asm.contains("call _tl_bind_args_onto"),
        "tl_eval assembly shows no bind-args-onto call (closure arg binding not wired):\n{}",
        asm,
    );

    // A symbol-head call probes the lexical env first via `env-has` to decide
    // between applying a closure-valued variable and calling a top-level `define`.
    assert!(
        asm.contains("call _tl_env_has"),
        "tl_eval assembly shows no env-has call (symbol-head closure-vs-define routing):\n{}",
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
        "\"string-append\"",
    ] {
        assert!(
            asm.contains(&format!(".string {op}")),
            "tl_eval assembly is missing the dispatch string literal for the string op {op}:\n{}",
            asm,
        );
    }

    // The `string-append` dispatch arm lowers the host `string-append` builtin to
    // a call into the emit-on-demand `tl_string_concat` runtime (it copies BOTH
    // operands' bytes into ONE fresh heap String — see the backend's
    // `generate_string_concat_runtime_functions`). Its definition AND at least one
    // call site must be present: this is the load-bearing wiring that lets the
    // interpreter BUILD strings, completing its string toolkit (measure / slice /
    // compare / print / build).
    assert!(
        asm.contains("tl_string_concat:"),
        "tl_eval assembly is missing the tl_string_concat runtime helper (string-append op):\n{}",
        asm,
    );
    assert!(
        asm.contains("call tl_string_concat"),
        "tl_eval assembly shows no string-append call (string-append op not lowered):\n{}",
        asm,
    );

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
    // list. The zip now lives in the generalised `bind-args-onto` (asserted above),
    // which walks both lists in lock-step, evaluates each argument in the caller
    // env, `EBind`s it to the matching parameter, and recurses on the tails;
    // `bind-args` is the thin `base = ENil` wrapper a top-level call uses (a
    // closure application instead passes the captured env). So a `bind-args` call
    // (the top-level user-function path) must be present, AND the zip recursion -
    // the `bind-args-onto` self-call - must be present (at least two
    // `call _tl_bind_args_onto`, which the `call _tl_bind_args` substring also
    // matches).
    assert!(
        asm.contains("call _tl_bind_args\n") || asm.contains("call _tl_bind_args "),
        "tl_eval assembly shows no bind-args call (no top-level multi-argument call binding):\n{}",
        asm,
    );
    assert!(
        asm.matches("call _tl_bind_args_onto").count() >= 2,
        "tl_eval assembly shows no recursive bind-args-onto self-call (param/arg zip):\n{}",
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

    // SEQUENCING (#27): the `begin` SPECIAL FORM `(begin e1 e2 ... en)` is
    // dispatched on its head-symbol text `"begin"` (checked BEFORE the builtin-op
    // and user-call paths, so it controls evaluation ORDER rather than being a
    // call), so that string literal must be emitted in the read-only data alongside
    // the other special forms.
    assert!(
        asm.contains(".string \"begin\""),
        "tl_eval assembly is missing the \"begin\" dispatch string literal (begin special form):\n{}",
        asm,
    );

    // CONS PAIRS / LINKED LISTS (#27): the value domain gains a `(VPair Value
    // Value)` cons cell built by the `cons` builtin and projected by `car` / `cdr`,
    // each dispatched in `eval-sexpr` on its head-symbol text. So the three dispatch
    // string literals must be emitted in the read-only data alongside the other
    // builtins.
    for op in ["\"cons\"", "\"car\"", "\"cdr\""] {
        assert!(
            asm.contains(&format!(".string {op}")),
            "tl_eval assembly is missing the dispatch string literal for the pair op {op} \
             (cons/car/cdr):\n{}",
            asm,
        );
    }

    // `car` / `cdr` of a non-pair value is a type error in the interpreted program,
    // reported by aborting via `panic` (the same channel `as-int`/`as-str` use), so
    // each op's "not a pair" abort message must reach the read-only data.
    for msg in ["\"car: not a pair\"", "\"cdr: not a pair\""] {
        assert!(
            asm.contains(&format!(".string {msg}")),
            "tl_eval assembly is missing the {msg} type-error message (car/cdr of a non-pair):\n{}",
            asm,
        );
    }

    // RECURSIVE LIST PRINTING (#27): a `VPair` no longer prints as the opaque
    // placeholder `#<pair>` - the `print` special form's pair arm now delegates to
    // the recursive `print-value` walk, which renders a list as
    // `(e1 e2 ... en)` (nesting parenthesised; an improper final cdr rendered in
    // DOTTED-PAIR notation `(a . b)`). So the
    // old `#<pair>` placeholder literal must be GONE, and the two new mutually
    // recursive printer helpers - `print-value` (dispatches on value shape) and
    // `print-list-tail` (walks the cdr chain emitting space-separated elements) -
    // must both be emitted as their own functions.
    assert!(
        !asm.contains(".string \"#<pair>\""),
        "tl_eval should no longer emit the \"#<pair>\" placeholder (VPair now prints as \
         a proper list `(...)` via the recursive print-value walk):\n{}",
        asm,
    );
    for sym in ["_tl_print_value:", "_tl_print_list_tail:"] {
        assert!(
            asm.contains(sym),
            "tl_eval assembly is missing the recursive list-printer helper {} \
             (VPair print arm):\n{}",
            sym,
            asm,
        );
    }

    // The list parens / element separator are emitted as string literals consumed by
    // the host `print-string` builtin: the opening `(`, the single-space separator
    // ` `, and the closing `)` reach the read-only data, and the list rendering is
    // backed by `tl_print_str` calls (asserted above for the VStr arm).
    for lit in ["\"(\"", "\")\"", "\" \""] {
        assert!(
            asm.contains(&format!(".string {lit}")),
            "tl_eval assembly is missing the list-rendering literal {lit} \
             (print-value/print-list-tail):\n{}",
            asm,
        );
    }

    // DOTTED-PAIR PRINTING (#27): an IMPROPER list (a cdr that is neither a `VPair`
    // nor the `(VInt 0)` nil sentinel) renders in the standard Lisp dotted-pair
    // notation `(a . b)`. `print-list-tail`'s improper-tail arms emit the ` . `
    // separator (space-dot-space) before `print-value`-ing the final non-nil cdr and
    // closing the paren, so `(cons 10 20)` prints `(10 . 20)`. That ` . ` separator
    // literal must reach the read-only data (it replaces the old stop-and-close
    // behaviour that dropped the cdr and printed `(10)`).
    assert!(
        asm.contains(".string \" . \""),
        "tl_eval assembly is missing the dotted-pair separator literal \" . \" \
         (improper-list printing in print-list-tail):\n{}",
        asm,
    );

    // The list printer is genuinely RECURSIVE: `print-value` and `print-list-tail`
    // call each other to walk the cons chain (and a nested pair element re-enters
    // `print-value`), so the `print` arm's dispatch call PLUS the mutual-recursion
    // call sites mean at least two `call _tl_print_value` sites must be present.
    assert!(
        asm.contains("call _tl_print_value"),
        "tl_eval assembly shows no print-value call (VPair list-printing not wired):\n{}",
        asm,
    );
    assert!(
        asm.matches("call _tl_print_value").count() >= 2,
        "tl_eval assembly shows no recursive print-value call (cons-chain / nested-list \
         walk):\n{}",
        asm,
    );
    assert!(
        asm.contains("call _tl_print_list_tail"),
        "tl_eval assembly shows no print-list-tail call (cdr-chain walk not wired):\n{}",
        asm,
    );

    // LIST PREDICATES (#27/#141): `(pair? x)` is true iff `x` evaluates to a
    // `(VPair ...)` and `(null? x)` is true iff `x` is the nil sentinel `(VInt 0)`
    // (this file reuses `(VInt 0)` as the empty-list NIL, #141), each dispatched in
    // `eval-sexpr` on its head-symbol text and folded to the 1/0 integer-truth
    // convention. Both are TOTAL over the value domain (a non-pair / non-nil is
    // simply false, never a type error). So the two dispatch string literals must be
    // emitted in the read-only data alongside the other builtins.
    for op in ["\"pair?\"", "\"null?\""] {
        assert!(
            asm.contains(&format!(".string {op}")),
            "tl_eval assembly is missing the dispatch string literal for the list \
             predicate {op} (pair?/null?):\n{}",
            asm,
        );
    }

    // VARIADIC LIST CONSTRUCTOR (#27): `(list e1 e2 ... en)` is a SPECIAL FORM
    // (variadic, so dispatched before the fixed-arity builtin-op / user-call paths)
    // that builds the right-nested cons chain `(VPair v1 (VPair v2 ... (VInt 0)))`
    // terminated by the `(VInt 0)` NIL sentinel - the same chain a nested `cons`
    // literal builds, so `pair?` / `null?` / `car` / `cdr` / `sum-list` walk it
    // identically. So its `"list"` head-symbol dispatch literal must reach the
    // read-only data alongside the other special forms.
    assert!(
        asm.contains(".string \"list\""),
        "tl_eval assembly is missing the \"list\" dispatch string literal (variadic list constructor):\n{}",
        asm,
    );

    // The `list` arm walks its element spine with `eval-list`, which evaluates each
    // element head-first and CONSES it onto the recursively built tail (terminating
    // at `(VInt 0)`). So `eval-list` is emitted as its own function, the dispatch arm
    // calls it, AND it calls ITSELF (the recursive spine cons-build) - so at least
    // two `call _tl_eval_list` sites must be present.
    assert!(
        asm.contains("_tl_eval_list:"),
        "tl_eval assembly is missing the eval-list helper (variadic list constructor):\n{}",
        asm,
    );
    assert!(
        asm.matches("call _tl_eval_list").count() >= 2,
        "tl_eval assembly shows no recursive eval-list self-call (list spine cons-build):\n{}",
        asm,
    );

    // RECURSIVE LIST ALGORITHMS (#27): the predicates exist so an interpreted
    // program can write recursive list functions that TERMINATE on the structure of
    // the list. `main`'s program defines `sum-list` (recurs on `(cdr l)` while
    // `(pair? l)`) and `list-len` (recurs until `(null? l)`), so the function names
    // are folded into the `FnEnv` via `is-define` and a recursive self-call resolves
    // through the shared `fenv`. The named functions are *interpreted* (their symbol
    // text lives in the program String, not as TypeLisp `_tl_` labels), so we assert
    // the predicate dispatch literals above plus the user-call wiring already
    // asserted (`lookup-fn-body`, `bind-args`) cover the recursive-list demo; no new
    // `_tl_sum_list:` label is emitted (the function lives in the interpreted
    // program, not the host).
    assert!(
        !asm.contains("_tl_sum_list:"),
        "sum-list is an INTERPRETED function (it lives in main's program String), so \
         no host `_tl_sum_list:` label should be emitted:\n{}",
        asm,
    );

    // HIGHER-ORDER FUNCTIONS - `map` / `filter` SHOWCASE (#27): `main`'s program
    // additionally defines `map` (`(define (map f l) (if (pair? l) (cons (f (car l))
    // (map f (cdr l))) 0))`) and `filter`, whose FIRST PARAMETER is a closure they
    // CALL on each element via `(f (car l))` / `(p (car l))`. Like `sum-list` these
    // are INTERPRETED functions (their text lives in the program String), so NO host
    // `_tl_map:` / `_tl_filter:` labels are emitted. What makes calling a
    // closure-VALUED PARAMETER work is the existing symbol-head dispatch: a call head
    // `f` that resolves to a `VClosure` in the value `env` is detected by `env-has`
    // and applied via `apply-value` (extending the captured env through
    // `bind-args-onto`) rather than looked up as a top-level `define` in the `fenv`.
    // That routing - `_tl_env_has:` / `_tl_apply_value:` / `_tl_bind_args_onto:` and
    // their call sites - is asserted above; this slice needs NO new host symbol (no
    // call-dispatch fix was required), only the interpreted `map`/`filter` defines.
    for gone in ["_tl_map:", "_tl_filter:"] {
        assert!(
            !asm.contains(gone),
            "map/filter are INTERPRETED functions (they live in main's program \
             String), so no host `{}` label should be emitted - the higher-order \
             call works through the existing env-has/apply-value closure-arg \
             routing:\n{}",
            gone,
            asm,
        );
    }

    // Building a `(VPair a b)` cons cell heap-allocates a two-field node (its fields
    // are `Value` pointers, #111), so the pair-building path goes through the
    // runtime allocator just like the `Sexpr` tree does. (`call tl_alloc` is already
    // asserted above for the Sexpr/token nodes; the VPair constructor adds more
    // allocation sites — the assertion above already covers presence.)

    // The `begin` arm walks its sub-expression spine with `eval-seq`, which
    // evaluates each form head-first (for its side effects) and recurses on the
    // tail, returning the LAST form's value. So `eval-seq` is emitted as its own
    // function (asserted in the symbol list above), the dispatch arm calls it, AND
    // it calls ITSELF (the recursive spine walk) - so at least two
    // `call _tl_eval_seq` sites must be present.
    assert!(
        asm.contains("call _tl_eval_seq"),
        "tl_eval assembly shows no eval-seq call (begin sequencing not lowered):\n{}",
        asm,
    );
    assert!(
        asm.matches("call _tl_eval_seq").count() >= 2,
        "tl_eval assembly shows no recursive eval-seq self-call (begin spine walk):\n{}",
        asm,
    );

    // The `seq` two-argument-function workaround `(define (seq a b) b)` is RETIRED
    // in favour of the `begin` special form, so the old `seq` helper must no longer
    // be emitted (TypeLisp prefixes user symbols with `_tl_`).
    assert!(
        !asm.contains("_tl_seq:"),
        "tl_eval should no longer define the seq sequencer helper (retired by the \
         begin special form):\n{}",
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

    // The runtime result composes a CLOSURE witness, a LIST-CONSTRUCTOR witness, a
    // recursive-list predicate witness, the RECURSIVE LIST PRINTER, AND
    // HIGHER-ORDER `map` / `filter` over interpreted lists:
    // `main`'s `begin` prints the string/recursion sum (`hello world3233\n`), two
    // closure applications (`25\n`, `15\n`), then the list/pair witness - it builds
    // the 3-element list with `(list 1 2 3)` and the pair `(cons 10 20)`, prints
    // the list's second element via `(car (cdr ...))` (`2\n`), the pair's car
    // (`10\n`), the predicate observations (`1\n`, `0\n`, `1\n`), and the recursive
    // list length (`3\n`), THEN the recursive list printer renders the proper list
    // `(1 2 3)`, a nested list `(1 (2 3) 4)`, the improper pair `(10 . 20)` (dotted-
    // pair notation), and the longer improper list `(1 2 . 3)`. The
    // higher-order showcase then prints `(1 4 9 16)` from `map` and `(1 2)` from
    // `filter`, before denoting the unprinted
    // `(sum-list (map (lambda (x) (* x x)) (list 1 2 3 4)))` =
    // `1 + 4 + 9 + 16` = `30`. All of this is computed by the interpreter at
    // RUNTIME (not a compile-time constant in this evaluator's own source), so we
    // do NOT assert the result appears in the assembly; the printed stdout
    // (`hello world3233\n25\n15\n2\n10\n1\n0\n1\n3\n(1 2 3)(1 (2 3) 4)(10 . 20)(1 2 . 3)(1 4 9 16)(1 2)`)
    // and exit code (`30`) are asserted by the Linux-gated exec test in
    // `tests/integration.rs`.

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
