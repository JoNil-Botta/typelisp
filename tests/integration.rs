#![cfg(target_os = "linux")]

use std::fs;
use std::path::PathBuf;
use std::process::Command;

struct Case {
    name: &'static str,
    exit_code: i32,
    stdout: &'static str,
    /// Additional source files (relative to tests/integration/) that the entry
    /// program imports; copied into the work dir preserving their relative path
    /// so `(import ...)` resolves. Empty for single-file programs.
    deps: &'static [&'static str],
}

#[test]
fn type_lisp_programs_compile_link_and_run() {
    let cases = [
        Case {
            name: "hello",
            exit_code: 42,
            stdout: "",
            deps: &[],
        },
        Case {
            name: "arithmetic",
            exit_code: 47,
            stdout: "",
            deps: &[],
        },
        Case {
            name: "factorial",
            exit_code: 120,
            stdout: "",
            deps: &[],
        },
        Case {
            name: "fibonacci",
            exit_code: 13,
            stdout: "",
            deps: &[],
        },
        Case {
            name: "control_flow",
            exit_code: 15,
            stdout: "",
            deps: &[],
        },
        Case {
            name: "functions",
            exit_code: 32,
            stdout: "",
            deps: &[],
        },
        Case {
            name: "print",
            exit_code: 0,
            stdout: "42\nfalse\n",
            deps: &[],
        },
        Case {
            name: "print_char",
            exit_code: 0,
            stdout: "A\n",
            deps: &[],
        },
        // refs #13/#27: `(print-string s)` / `(print-str s)` writes a whole
        // String's bytes to stdout via a single write(1) syscall. The "\n"
        // escapes lex to real newline bytes, so the program emits exactly
        // "hello\nworld\n" and exits 0 — unblocking printing String values.
        Case {
            name: "print_string",
            exit_code: 0,
            stdout: "hello\nworld\n",
            deps: &[],
        },
        Case {
            name: "unit_functions",
            exit_code: 7,
            stdout: "",
            deps: &[],
        },
        Case {
            name: "unit_main",
            exit_code: 0,
            stdout: "",
            deps: &[],
        },
        Case {
            name: "tl_alloc",
            exit_code: 0,
            stdout: "",
            deps: &[],
        },
        Case {
            name: "many_args",
            exit_code: 36,
            stdout: "",
            deps: &[],
        },
        Case {
            name: "narrow_div_mod",
            exit_code: 30,
            stdout: "",
            deps: &[],
        },
        Case {
            name: "string_length",
            exit_code: 5,
            stdout: "",
            deps: &[],
        },
        Case {
            name: "string_eq",
            exit_code: 0,
            stdout: "true\nfalse\nfalse\ntrue\n",
            deps: &[],
        },
        Case {
            name: "substring",
            exit_code: 33,
            stdout: "",
            deps: &[],
        },
        // refs #13/#27: `(string-append a b)` / `(string-concat a b)` joins two
        // Strings into a fresh heap String via the emit-on-demand, libc-free
        // `tl_string_concat` runtime. The program prints "foo"+"bar" then a
        // "\n"+"" concatenation, so stdout is exactly "foobar\n" and it exits 0 —
        // unblocking exposing concatenation in the interpreter.
        Case {
            name: "string_append",
            exit_code: 0,
            stdout: "foobar\n",
            deps: &[],
        },
        // Multi-file program (#44): entry imports a helper module and calls a
        // function defined there; exercises the module-graph loader end to end.
        Case {
            name: "modules_main",
            exit_code: 30,
            stdout: "",
            deps: &["modules_helper.tl"],
        },
        // Enum definition, constructor, and pattern matching end to end.
        Case {
            name: "enum_match",
            exit_code: 42,
            stdout: "",
            deps: &[],
        },
        // Self-hosting (#27, phase 4): a tokenizer written in TypeLisp itself.
        // Lexes "foo - 3 * (12 / 4)" into 9 tokens: TIdent("foo") TMinus
        // TInt(3) TStar TLParen TInt(12) TSlash TInt(4) TRParen — exercising
        // every operator (`- * /`). The first token is read back from
        // `(Array Token)` and its substring-sliced text is projected out of
        // `(TIdent "foo")`. `main` returns token count (9) + identifier text
        // length (3) = 12.
        Case {
            name: "lexer",
            exit_code: 12,
            stdout: "",
            deps: &[],
        },
        // refs #27/#41: a String-payload enum variant constructed, returned
        // across a function boundary (heap-promoted), and its payload bound
        // back out in a `match` arm. `(TIdent "hello")` -> length 5.
        Case {
            name: "enum_string_payload",
            exit_code: 5,
            stdout: "",
            deps: &[],
        },
        // refs #13/#27: recursive enum payloads. Builds `(EAdd (ENum 1)
        // (ENum 2))` as a heap-allocated tree (each `Expr` child is an 8-byte
        // heap pointer) and folds it with a recursive `eval`. `main` returns 3.
        Case {
            name: "tree",
            exit_code: 3,
            stdout: "",
            deps: &[],
        },
        // Self-hosting (#27, phase 4): a recursive-descent precedence parser
        // written in TypeLisp. Parses the token stream for "2 + 3 * 4" over the
        // grammar expr := term (('+'|'-') term)*, term := factor (('*'|'/')
        // factor)*, factor := int | '(' expr ')' into a REAL recursive `Expr`
        // AST tree — (EAdd (ENum 2) (EMul (ENum 3) (ENum 4))), whose payloads
        // are heap-pointer indirections (#111) — then folds it with a recursive
        // tree-walking `eval`. `*` binds tighter than `+`, so the result is
        // 2 + (3 * 4) = 14, not (2 + 3) * 4 = 20.
        Case {
            name: "parser",
            exit_code: 14,
            stdout: "",
            deps: &[],
        },
        // Self-hosting (#27, phase 4): the whole TypeLisp front end composed end
        // to end. `calc.tl` lexes the source "2 + 3 * 4" into a real
        // `(Array Token)`, the recursive-descent precedence parser reads tokens
        // straight out of that array into a real recursive `Expr` AST, and a
        // tree-walking `eval` folds it: `(eval (parse (lex "2 + 3 * 4")))`. `*`
        // binds tighter than `+`, so the result is 2 + (3 * 4) = 14, NOT
        // (2 + 3) * 4 = 20 — proving the composed pipeline honours precedence.
        // The shared `Token` model lives in the `main`-less `token.tl`, which
        // `calc.tl` imports; it is copied alongside so the import resolves.
        Case {
            name: "calc",
            exit_code: 14,
            stdout: "",
            deps: &["token.tl"],
        },
        // Self-hosting (#27): the lexer for TypeLisp's OWN s-expression syntax
        // (NOT the arithmetic-calculator surface). `tl_lexer.tl` tokenizes real
        // TypeLisp source - balanced parens, integer literals, *symbols*
        // (operators / keywords / names are all one `TSym` kind), STRING LITERALS
        // (`"..."` => `TStr`), and `;` line comments (skipped) - into a real
        // `(Array Token)`, slicing each lexeme out of the source with `substring`
        // (and parsing ints with `string->int`). `main` lexes the escaped sample
        // "(foo \"hi\" 42) ; c\n(bar)" into TLParen TSym(foo) TStr(hi) TInt(42)
        // TRParen TLParen TSym(bar) TRParen (the `; c` comment drops out): 8
        // tokens with 1 TStr, so it returns total (8) + TStr count (1) = 9. The
        // token model lives in the `main`-less `tl_token.tl`, imported by
        // `tl_lexer.tl` and copied alongside.
        Case {
            name: "tl_lexer",
            exit_code: 9,
            stdout: "",
            deps: &["tl_token.tl"],
        },
        // Self-hosting (#27): the s-expression READER for TypeLisp's own syntax -
        // the canonical Lisp reader. `tl_reader.tl` consumes the lexer's
        // `(Array Token)` into the recursive cons-cell `Sexpr` AST
        // (SInt | SSym | SStr | SNil | SCons) with a token cursor and mutually
        // recursive `read-form` / `read-list`. It REUSES the lexer by importing
        // `lex` from the `main`-less `tl_lex.tl` (which transitively imports the
        // `main`-less `tl_token.tl`), so the whole program has one `main` - the
        // reader's. The reader now also consumes the lexer's `TStr` token (#128)
        // into a new `(SStr String)` atom, kept distinct from a same-character
        // `SSym` (#27). `main` reads `(greet "hi" 7 (msg "yo" 35))` into the Sexpr
        // tree and folds it two ways: `sum-ints` sums every integer atom
        // (7 + 35 => 42) and `count-strs` tallies every `SStr` atom - "hi" at the
        // top level and "yo" nested one list deep => 2 - so the result is
        // 42 + 2 => 44, witnessing BOTH that integers still read through nesting
        // AND that `"..."` literals read into `SStr` at every depth. Both imported
        // `main`-less modules are copied alongside so the `(import)` chain resolves.
        Case {
            name: "tl_reader",
            exit_code: 44,
            stdout: "",
            deps: &["tl_lex.tl", "tl_token.tl"],
        },
        // Self-hosting (#27): the s-expression EVALUATOR for TypeLisp's own
        // syntax, now a REAL LANGUAGE - a tiny tree-walking interpreter with
        // VARIABLES, MULTI-BINDING lexical `let` (sequential `let*` scoping),
        // short-circuit `if`, comparison operators,
        // USER-DEFINED FUNCTIONS plus RECURSION and MULTI-ARGUMENT calls via
        // top-level `(define (f x y z) body)` forms, a tagged VALUE domain
        // `(defenum Value (VInt i64) (VStr String))`, AND now STRING OPERATIONS
        // (`substring` / `string-length` / `string-eq` / `int->string` /
        // `string->int`). `tl_eval.tl` walks the
        // recursive cons-cell `Sexpr` AST
        // against two environments - a value `Env` (binding `Value`s) and a
        // function `FnEnv`: `(SSym name)` resolves via recursive assoc-list
        // `lookup`, `let` folds its binding LIST into the env (each init evaluated
        // in the env built so far - `let*` - then the body evaluated in the
        // extended env), integer-requiring contexts funnel through `as-int` and
        // string-requiring contexts through `as-str`, a string-op or builtin op
        // dispatches on its head-symbol text (unwrapping its operands and
        // re-wrapping the host builtin's result as a `Value`), and any other head
        // symbol is a CALL into the
        // `FnEnv` (look up the PARAMETER LIST + body, zip the params against the
        // args with `bind-args` to build a fresh callee env, eval body with the
        // SAME `FnEnv`, so a body can call itself with any arity). The `print`
        // special form prints BOTH value shapes: a `VInt` via the host `print`
        // (integer + newline), a `VStr` via the host `print-string` (raw bytes, NO
        // newline). `main` runs `run-program` over the THREE-form program
        // `(define (pow b e) (if (< e 1) 1 (* b (pow b (- e 1))))) (define (seq a b) b)
        //  (let ((s "hello world") (h (substring s 0 5)) (n (string-length h))
        //        (t (int->string (pow 2 n))) (m (string->int t)))
        //    (seq (seq (print h) (print t)) (print (+ m (string-eq h "hello")))))`:
        // the recursive TWO-parameter `pow` and a two-parameter `seq` (whose body
        // is its SECOND argument - a left-to-right sequencer, the interpreted
        // language having no `begin`) are folded into the `FnEnv`, then the trailing
        // MULTI-BINDING `let` binds `s` to the string VALUE `"hello world"`, then
        // `h` to `(substring s 0 5)` = `"hello"` (its init SEES the earlier `s` -
        // sequential `let*` scoping), then `n` to `(string-length h)` = `5`, then
        // `t` to `(int->string (pow 2 n))` = `(int->string 32)` = the string
        // `"32"` (the `int->string` op), then `m` to `(string->int t)` = `32` (the
        // inverse `string->int` op - an int<->string round-trip). The body
        // `(seq (seq (print h) (print t)) (print (+ m (string-eq h "hello"))))`
        // evaluates left-to-right: FIRST `(print h)` prints `hello` via the `VStr`
        // arm (host `print-string`, no newline), SECOND `(print t)` prints `32`
        // (the `VStr` arm again, no newline - the visible witness of `int->string`),
        // THIRD `(print (+ m (string-eq h "hello")))` = `(+ 32 1)` = `33\n` via the
        // `VInt` arm; the outer `seq` returns its second arg `(VInt 33)`. So stdout
        // is `hello3233\n`; printing to stdout escapes the old mod-256 exit-code
        // ceiling, so the exit code is the wrapped `33 & 0xff = 33`. All three
        // imported `main`-less modules are copied alongside so the `(import)` chain
        // resolves.
        Case {
            name: "tl_eval",
            exit_code: 33,
            stdout: "hello3233\n",
            deps: &["tl_read.tl", "tl_lex.tl", "tl_token.tl"],
        },
        // refs #41: NESTED PATTERN MATCHING, standalone witness. A tree-walking
        // evaluator whose SCons arm destructures two enum layers in ONE pattern
        // - `(SCons (SSym name) rest)` - binding the operator symbol `name` and
        // the argument spine `rest` together. `main` evaluates `(+ 1 (* 2 3))`:
        // the nested `(* 2 3)` is evaluated first (6), then `(+ 1 6)` => 7. A
        // non-symbol operator head would fail the nested `SSym` test and fall
        // through to the `_` arm, exactly like a flat tag mismatch.
        Case {
            name: "nested_eval",
            exit_code: 7,
            stdout: "",
            deps: &[],
        },
    ];

    for case in cases {
        run_case(&case);
    }
}

#[test]
fn type_lisp_programs_compile_link_and_run_explicit_build() {
    let cases = [
        Case {
            name: "hello",
            exit_code: 42,
            stdout: "",
            deps: &[],
        },
        Case {
            name: "arithmetic",
            exit_code: 47,
            stdout: "",
            deps: &[],
        },
        Case {
            name: "factorial",
            exit_code: 120,
            stdout: "",
            deps: &[],
        },
        Case {
            name: "fibonacci",
            exit_code: 13,
            stdout: "",
            deps: &[],
        },
        Case {
            name: "control_flow",
            exit_code: 15,
            stdout: "",
            deps: &[],
        },
        Case {
            name: "functions",
            exit_code: 32,
            stdout: "",
            deps: &[],
        },
        Case {
            name: "print",
            exit_code: 0,
            stdout: "42\nfalse\n",
            deps: &[],
        },
        Case {
            name: "print_char",
            exit_code: 0,
            stdout: "A\n",
            deps: &[],
        },
        // refs #13/#27: `print-string`/`print-str` write(1)-syscall builtin, also
        // exercised through the explicit compile -> as -> ld -> run pipeline.
        // Emits "hello\nworld\n" and exits 0.
        Case {
            name: "print_string",
            exit_code: 0,
            stdout: "hello\nworld\n",
            deps: &[],
        },
        Case {
            name: "unit_functions",
            exit_code: 7,
            stdout: "",
            deps: &[],
        },
        Case {
            name: "unit_main",
            exit_code: 0,
            stdout: "",
            deps: &[],
        },
        Case {
            name: "tl_alloc",
            exit_code: 0,
            stdout: "",
            deps: &[],
        },
        Case {
            name: "many_args",
            exit_code: 36,
            stdout: "",
            deps: &[],
        },
        Case {
            name: "narrow_div_mod",
            exit_code: 30,
            stdout: "",
            deps: &[],
        },
        Case {
            name: "string_length",
            exit_code: 5,
            stdout: "",
            deps: &[],
        },
        Case {
            name: "string_eq",
            exit_code: 0,
            stdout: "true\nfalse\nfalse\ntrue\n",
            deps: &[],
        },
        Case {
            name: "substring",
            exit_code: 33,
            stdout: "",
            deps: &[],
        },
        // refs #13/#27: string concatenation via `tl_string_concat`, also through
        // the explicit compile -> as -> ld -> run pipeline. Prints "foobar\n".
        Case {
            name: "string_append",
            exit_code: 0,
            stdout: "foobar\n",
            deps: &[],
        },
        Case {
            name: "modules_main",
            exit_code: 30,
            stdout: "",
            deps: &["modules_helper.tl"],
        },
        Case {
            name: "enum_match",
            exit_code: 42,
            stdout: "",
            deps: &[],
        },
        // Self-hosting (#27, phase 4): the TypeLisp tokenizer, also exercised
        // through the explicit compile -> as -> ld -> run pipeline. Lexes
        // "foo - 3 * (12 / 4)" into 9 tokens (exercising the `- * /` operators)
        // and reads the first identifier token back from `(Array Token)`;
        // `main` returns 9 + 3 = 12.
        Case {
            name: "lexer",
            exit_code: 12,
            stdout: "",
            deps: &[],
        },
        // refs #27/#41: String-payload variant construct/return/match, also
        // through the explicit compile -> as -> ld -> run pipeline.
        Case {
            name: "enum_string_payload",
            exit_code: 5,
            stdout: "",
            deps: &[],
        },
        // refs #13/#27: recursive enum payloads, also through the explicit
        // compile -> as -> ld -> run pipeline. Builds and folds `(EAdd (ENum 1)
        // (ENum 2))`; `main` returns 3.
        Case {
            name: "tree",
            exit_code: 3,
            stdout: "",
            deps: &[],
        },
        // Self-hosting (#27, phase 4): the TypeLisp recursive-descent precedence
        // parser, also exercised through the explicit compile -> as -> ld -> run
        // pipeline. Parses "2 + 3 * 4" into a real recursive `Expr` AST tree
        // (EAdd (ENum 2) (EMul (ENum 3) (ENum 4))) and folds it with a recursive
        // `eval`; `*` binds tighter than `+`, so `main` returns 2 + 3*4 = 14.
        Case {
            name: "parser",
            exit_code: 14,
            stdout: "",
            deps: &[],
        },
        // Self-hosting (#27, phase 4): the whole TypeLisp front end composed end
        // to end, also through the explicit compile -> as -> ld -> run pipeline.
        // Lexes "2 + 3 * 4" into a real `(Array Token)`, parses it into the
        // recursive `Expr` AST, and folds it with `eval`; `main` returns
        // 2 + (3 * 4) = 14. The shared `Token` model lives in the `main`-less
        // `token.tl`, imported by `calc.tl` and copied alongside.
        Case {
            name: "calc",
            exit_code: 14,
            stdout: "",
            deps: &["token.tl"],
        },
        // Self-hosting (#27): the TypeLisp-syntax (s-expression) lexer - now with
        // string literals (`TStr`) and `;` line comments - also exercised through
        // the explicit compile -> as -> ld -> run pipeline. Lexes the escaped
        // sample "(foo \"hi\" 42) ; c\n(bar)" into 8 tokens (1 of them a TStr;
        // the `; c` comment is skipped) and returns total (8) + TStr count (1) =
        // 9. The `main`-less `tl_token.tl` is copied alongside so the `(import)`
        // resolves.
        Case {
            name: "tl_lexer",
            exit_code: 9,
            stdout: "",
            deps: &["tl_token.tl"],
        },
        // Self-hosting (#27): the s-expression reader, also exercised through the
        // explicit compile -> as -> ld -> run pipeline. Reads
        // `(greet "hi" 7 (msg "yo" 35))` into the recursive cons-cell `Sexpr` AST
        // and folds it two ways: `sum-ints` sums every integer atom (7 + 35 => 42)
        // and `count-strs` tallies every `SStr` atom the reader produced from the
        // lexer's `TStr` tokens (#128) - "hi" and the nested "yo" => 2 - so the
        // result is 42 + 2 => 44. The lexer is reused via the `main`-less
        // `tl_lex.tl` import (which transitively imports `tl_token.tl`); both are
        // copied alongside so the imports resolve.
        Case {
            name: "tl_reader",
            exit_code: 44,
            stdout: "",
            deps: &["tl_lex.tl", "tl_token.tl"],
        },
        // Self-hosting (#27): the s-expression evaluator with variables,
        // MULTI-BINDING `let` (sequential `let*`),
        // `if`, comparisons, user-defined functions + recursion + MULTI-ARGUMENT
        // calls, a tagged VALUE domain `(VInt/VStr)` whose BOTH shapes print
        // (`VInt` via host `print`, `VStr` via host `print-string`), AND STRING
        // OPERATIONS (`substring` / `string-length` / `string-eq` / `int->string` /
        // `string->int`), also
        // exercised through the explicit compile -> as -> ld -> run pipeline.
        // Runs `run-program` over the three-form program
        // `(define (pow b e) (if (< e 1) 1 (* b (pow b (- e 1))))) (define (seq a b) b)
        //  (let ((s "hello world") (h (substring s 0 5)) (n (string-length h))
        //        (t (int->string (pow 2 n))) (m (string->int t)))
        //    (seq (seq (print h) (print t)) (print (+ m (string-eq h "hello")))))`:
        // `pow` and the sequencer `seq` are folded into the `FnEnv`, then the
        // multi-binding `let` binds `s`->"hello world", `h`->(substring s 0 5) =
        // "hello" (the init sees the earlier `s` - sequential `let*` scoping),
        // `n`->(string-length h) = 5, `t`->(int->string (pow 2 n)) = "32" (the
        // `int->string` op), `m`->(string->int t) = 32 (the inverse `string->int`
        // op - an int<->string round-trip); the body
        // `(seq (seq (print h) (print t)) (print ...))` prints `hello` then `32`
        // (both the `VStr` arm, host `print-string`, no newline) then
        // `(+ m (string-eq h "hello"))` = `(+ 32 1)` = `33\n` (the `VInt` arm) and
        // the outer `seq` returns `(VInt 33)` - so stdout is `hello3233\n` and the
        // exit code is the wrapped `33 & 0xff = 33`. The reader (and transitively
        // the lexer + token
        // model) is reused via the `main`-less `tl_read.tl` import - including its
        // lower-level `read-form` cursor entry, which the program reader drives to
        // read all top-level forms; all three imported modules are copied
        // alongside so the imports resolve.
        Case {
            name: "tl_eval",
            exit_code: 33,
            stdout: "hello3233\n",
            deps: &["tl_read.tl", "tl_lex.tl", "tl_token.tl"],
        },
        // refs #41: nested pattern matching, also through the explicit
        // compile -> as -> ld -> run pipeline. `(SCons (SSym name) rest)`
        // destructures two enum layers in one arm; `main` evaluates
        // `(+ 1 (* 2 3))` => 7.
        Case {
            name: "nested_eval",
            exit_code: 7,
            stdout: "",
            deps: &[],
        },
    ];

    for case in cases {
        run_case_explicit_build(&case);
    }
}

fn run_case_explicit_build(case: &Case) {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let source_path = manifest_dir
        .join("tests")
        .join("integration")
        .join(format!("{}.tl", case.name));
    let work_dir = manifest_dir
        .join("target")
        .join("integration-tests-explicit")
        .join(case.name);
    fs::create_dir_all(&work_dir).expect("create explicit build test work dir");
    let work_path = work_dir.join(format!("{}.tl", case.name));
    fs::copy(&source_path, &work_path).expect("copy TypeLisp program to work dir");

    // Copy any imported helper modules alongside the entry file.
    for dep in case.deps {
        let dep_src = manifest_dir.join("tests").join("integration").join(dep);
        let dep_dst = work_dir.join(dep);
        if let Some(parent) = dep_dst.parent() {
            fs::create_dir_all(parent).expect("create dep work dir");
        }
        fs::copy(&dep_src, &dep_dst).expect("copy imported module to work dir");
    }

    let asm_path = work_path.with_extension("s");
    let obj_path = work_path.with_extension("o");
    let bin_path = work_path.with_extension("");

    // Compile .tl → .s using the "compile" subcommand
    let output = Command::new(env!("CARGO_BIN_EXE_typelisp"))
        .arg("compile")
        .arg(&work_path)
        .output()
        .expect("run typelisp compile");

    let compile_stdout = String::from_utf8_lossy(&output.stdout);
    let compile_stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        output.status.success(),
        "{} compile step failed\nstdout:\n{}\nstderr:\n{}",
        case.name,
        compile_stdout,
        compile_stderr,
    );

    // Assemble .s → .o
    let status = Command::new("as")
        .arg(&asm_path)
        .arg("-o")
        .arg(&obj_path)
        .status()
        .expect("run assembler");
    assert!(status.success(), "{} assembly failed", case.name);

    // Link .o → binary
    let status = Command::new("ld")
        .arg(&obj_path)
        .arg("-o")
        .arg(&bin_path)
        .arg("-dynamic-linker")
        .arg("/lib64/ld-linux-x86-64.so.2")
        .arg("-lc")
        .status()
        .expect("run linker");
    assert!(status.success(), "{} linking failed", case.name);

    // Run binary
    let output = Command::new(&bin_path)
        .output()
        .expect("run compiled binary");

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert_eq!(
        output.status.code(),
        Some(case.exit_code),
        "{} exited unexpectedly\nstdout:\n{}\nstderr:\n{}",
        case.name,
        stdout,
        stderr,
    );
    assert_eq!(
        stdout, case.stdout,
        "{} stdout differed\nstderr:\n{}",
        case.name, stderr,
    );
}

fn run_case(case: &Case) {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let source_path = manifest_dir
        .join("tests")
        .join("integration")
        .join(format!("{}.tl", case.name));
    let work_dir = manifest_dir
        .join("target")
        .join("integration-tests")
        .join(case.name);
    fs::create_dir_all(&work_dir).expect("create integration test work dir");
    let work_path = work_dir.join(format!("{}.tl", case.name));
    fs::copy(&source_path, &work_path).expect("copy TypeLisp program to work dir");

    // Copy any imported helper modules alongside the entry file, preserving
    // their relative path so `(import "...")` resolves at load time.
    for dep in case.deps {
        let dep_src = manifest_dir.join("tests").join("integration").join(dep);
        let dep_dst = work_dir.join(dep);
        if let Some(parent) = dep_dst.parent() {
            fs::create_dir_all(parent).expect("create dep work dir");
        }
        fs::copy(&dep_src, &dep_dst).expect("copy imported module to work dir");
    }

    let output = Command::new(env!("CARGO_BIN_EXE_typelisp"))
        .arg("run")
        .arg(&work_path)
        .output()
        .expect("run typelisp");

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert_eq!(
        output.status.code(),
        Some(case.exit_code),
        "{} exited unexpectedly\nstdout:\n{}\nstderr:\n{}",
        case.name,
        stdout,
        stderr
    );
    assert_eq!(
        stdout, case.stdout,
        "{} stdout differed\nstderr:\n{}",
        case.name, stderr
    );
}
