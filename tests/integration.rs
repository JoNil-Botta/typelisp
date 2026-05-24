#![cfg(target_os = "linux")]

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

struct Case {
    name: &'static str,
    exit_code: i32,
    stdout: &'static str,
    /// Additional source files that the entry program imports; copied into the
    /// work dir preserving their relative path so `(import ...)` resolves.
    /// Most deps are relative to the entry source directory; selected fixtures
    /// are sourced from their canonical `selfhost/` or `stdlib/` modules.
    deps: &'static [&'static str],
}

const TL_EMIT_PROGRAM_ASM: &str = concat!(
    "    .text\n",
    "    .globl main\n",
    "    .globl _start\n",
    "\n",
    "main:\n",
    "    push %rbp\n",
    "    mov %rsp, %rbp\n",
    "    movq $1, %rax\n",
    "    pushq %rax\n",
    "    movq $2, %rax\n",
    "    pushq %rax\n",
    "    movq $3, %rax\n",
    "    movq %rax, %rcx\n",
    "    popq %rax\n",
    "    imulq %rcx, %rax\n",
    "    movq %rax, %rcx\n",
    "    popq %rax\n",
    "    addq %rcx, %rax\n",
    "    pop %rbp\n",
    "    ret\n",
    "\n",
    "_start:\n",
    "    call main\n",
    "    movq %rax, %rdi\n",
    "    movq $60, %rax\n",
    "    syscall\n",
);

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
            name: "comptime_scalar",
            exit_code: 3,
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
            name: "fixed_array",
            exit_code: 42,
            stdout: "",
            deps: &[],
        },
        Case {
            name: "format_doc_integration",
            exit_code: 42,
            stdout: "",
            deps: &["format_doc.tl"],
        },
        Case {
            name: "format_cst_integration",
            exit_code: 42,
            stdout: "",
            deps: &["format_cst.tl", "format_tokens.tl"],
        },
        Case {
            name: "format_core_integration",
            exit_code: 42,
            stdout: "",
            deps: &[
                "format_core.tl",
                "format_cst.tl",
                "format_tokens.tl",
                "format_doc.tl",
            ],
        },
        Case {
            name: "format_rules_integration",
            exit_code: 42,
            stdout: "",
            deps: &[
                "format_rules.tl",
                "format_cst.tl",
                "format_tokens.tl",
                "format_doc.tl",
            ],
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
            name: "global_initializer",
            exit_code: 120,
            stdout: "",
            deps: &[],
        },
        Case {
            name: "aggregate_globals",
            exit_code: 42,
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
            name: "cond",
            exit_code: 42,
            stdout: "",
            deps: &[],
        },
        Case {
            name: "spmd_foreach",
            exit_code: 42,
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
            name: "function_pointer_values",
            exit_code: 42,
            stdout: "",
            deps: &[],
        },
        Case {
            name: "lambda_lift",
            exit_code: 42,
            stdout: "",
            deps: &[],
        },
        Case {
            name: "lambda_capture_scalar",
            exit_code: 42,
            stdout: "",
            deps: &[],
        },
        Case {
            name: "lambda_capture_aggregate",
            exit_code: 42,
            stdout: "",
            deps: &[],
        },
        Case {
            name: "lambda_capture_tuple",
            exit_code: 42,
            stdout: "",
            deps: &[],
        },
        Case {
            name: "lambda_capture_struct_enum",
            exit_code: 42,
            stdout: "",
            deps: &[],
        },
        Case {
            name: "lambda_capture_nested_aggregate",
            exit_code: 42,
            stdout: "",
            deps: &[],
        },
        Case {
            name: "lambda_aggregate_returns",
            exit_code: 42,
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
            name: "overflow_casts",
            exit_code: 0,
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
            name: "string_match",
            exit_code: 42,
            stdout: "",
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
        // Tuple locals lower to inline storage and tuple-ref reads scalar fields.
        Case {
            name: "tuple_values",
            exit_code: 42,
            stdout: "",
            deps: &[],
        },
        // refs #41, GAP (D): the zero-arg call form `(Ctor)` constructs a NULLARY
        // enum variant. `main` builds `(Red)` and `(Green)` via the call form (the
        // same construction bare `Red`/`Green` would produce), the payload variant
        // `(RGB 9)`, and calls the zero-arg FUNCTION `(bias)` (30) — proving the
        // disambiguation rule (a function name still calls). code(Red)=1 +
        // code(Green)=2 + code(RGB 9)=9 + bias=30 = 42.
        Case {
            name: "nullary_variant_call",
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
        // refs #228: monomorphic Maybe/Result convention. Named functions
        // return absence and success/error enums, and callers handle every
        // variant with explicit exhaustive matches. main = 42 + 10 + 7 + 6.
        Case {
            name: "maybe_result",
            exit_code: 65,
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
        // Self-hosting M1 (#155/#156): the first backend-shaped TypeLisp emitter
        // and driver. `emit.tl` builds `(+ 1 (* 2 3))`, wraps its emitted body
        // in the backend-shaped `main` + `_start` skeleton, and prints the full
        // `.s`. This test asserts the exact printed assembly text.
        Case {
            name: "tl_emit",
            exit_code: 0,
            stdout: TL_EMIT_PROGRAM_ASM,
            deps: &["emit_core.tl", "ast_types.tl", "sym_i64_env.tl"],
        },
        // Self-hosting M1 (#154/#173): parse the reader's generic Sexpr tree
        // into the compiler AST shared with `emit.tl`. The witness parses
        // arithmetic, define, let, if, comparison operators, string literals,
        // and print forms, then returns a stable structural score. The raw score
        // is 685; process exit observes it modulo 256, so the Linux exit code is
        // 173.
        Case {
            name: "tl_ast",
            exit_code: 173,
            stdout: "",
            deps: &["ast_types.tl", "read.tl", "lex.tl", "token.tl"],
        },
        // Self-hosting (#27): the lexer for TypeLisp's OWN s-expression syntax
        // (NOT the arithmetic-calculator surface). `lexer.tl` tokenizes real
        // TypeLisp source - balanced parens, integer literals, *symbols*
        // (operators / keywords / names are all one `TSym` kind), string literals,
        // character literals, and `;` line comments (skipped) - into a real
        // `(Array Token)`. `main` lexes a sample with `#x'`, `#\n'`, `#\space'`,
        // and `#\newline'`, verifies their decoded code sum, checks the
        // recoverable `lex-result` error path, and returns 12 tokens + 1 string
        // + 4 chars = 17.
        Case {
            name: "tl_lexer",
            exit_code: 17,
            stdout: "",
            deps: &["lex.tl", "token.tl"],
        },
        // Self-hosting (#27): the s-expression READER for TypeLisp's own syntax -
        // the canonical Lisp reader. `reader.tl` consumes the lexer's
        // `(Array Token)` into the recursive cons-cell `Sexpr` AST
        // (SInt | SSym | SStr | SChar | SNil | SCons) with a token cursor and mutually
        // recursive `read-form` / `read-list`. It REUSES the lexer by importing
        // `lex` from the `main`-less `lex.tl` (which transitively imports the
        // `main`-less `token.tl`), so the whole program has one `main` - the
        // reader's. The reader consumes lexer `TStr` and `TChar` tokens into
        // distinct `SStr` and `SChar` atoms. `main` reads a nested sample, sums
        // ints to 42, counts two strings, counts four chars, verifies decoded char
        // codes sum to 172, and checks three recoverable reader diagnostics,
        // returning 42 + 2 + 4 + 10 + 3 = 61.
        Case {
            name: "tl_reader",
            exit_code: 61,
            stdout: "",
            deps: &["lex.tl", "token.tl"],
        },
        // Self-hosting (#27): the s-expression EVALUATOR for TypeLisp's own
        // syntax, now with FIRST-CLASS FUNCTIONS (`lambda` + CLOSURES), CONS PAIRS /
        // LINKED LISTS, AND the `pair?` / `null?` LIST PREDICATES that let an
        // interpreted program write RECURSIVE LIST ALGORITHMS - on top of variables,
        // multi-binding `let`, `if`, comparisons, the `begin` SEQUENCING special
        // form, recursion, multi-arg user functions, and the string ops. The tagged
        // VALUE domain is `(VInt/VStr/VClosure/VPair)`: a `(lambda (p...) body)`
        // builds a `(VClosure params body captured-env)` capturing the current
        // lexical env (applied as a computed operator `((lambda ...) a)` or a
        // closure-valued variable `(f a)`, with free variables resolved through the
        // captured env via `bind-args-onto`), and `(cons a b)` builds a `(VPair a b)`
        // cell that `car` / `cdr` project and the recursive list printer can render
        // as `(...)`; `(pair? x)` is true iff `x` is a `(VPair ...)` and `(null? x)`
        // is true iff `x` is the nil sentinel `(VInt 0)` (refs #141), both folded to
        // 1/0. `Value` and `Env` are mutually recursive enums (a `VClosure` carries
        // an `Env`, an `EBind` carries a `Value`), each pointer-sized so the layout
        // stays finite. `main` runs `run-program` over a program that defines a
        // recursive `pow`, the list accessor `second` = `(car (cdr xs))`, and two
        // RECURSIVE LIST functions - `sum-list` (recurs while `(pair? l)`) and
        // `list-len` (recurs until `(null? l)`) - then a four-arm `begin`: (1) a
        // string-heavy `let` prints `hello world32` and `33\n` (recursion, multi-arg
        // calls, the string toolkit); (2) immediate application
        // `((lambda (x) (* x x)) 5)` -> `25\n`; (3) captured free variable `n = 10`
        // via `((lambda (x) (+ x n)) 5)` -> `15\n`; (4) the LIST-CONSTRUCTOR /
        // PREDICATE / RECURSIVE-LIST witness - `lst = (list 1 2 3)` (the variadic
        // `list` SPECIAL FORM, denoting the 3-element right-nested cons chain
        // terminated by the `0` NIL sentinel) and `p = (cons 10 20)`: prints the
        // list's second element `2\n`, the pair's car `10\n`, `(pair? lst)` `1\n`,
        // `(null? lst)` `0\n`, `(null? 0)` `1\n`, and the recursive `(list-len lst)`
        // `3\n` (proving the `list`-built chain is indistinguishable from a nested
        // `cons` literal to every list op). THEN the RECURSIVE LIST PRINTER (#27):
        // `(print lst)` renders the proper list as `(1 2 3)`, `(print (list 1 (list
        // 2 3) 4))` a nested list as `(1 (2 3) 4)` (the inner pair element recurses
        // parenthesised), `(print p)` the IMPROPER pair `(cons 10 20)` in DOTTED-PAIR
        // notation as `(10 . 20)`, and `(print (cons 1 (cons 2 3)))` the longer
        // improper list as `(1 2 . 3)` (proper-prefix elements normal, final non-nil
        // cdr dotted); these list renderings carry NO trailing newline (like the
        // VStr/VClosure arms).
        // THEN the HIGHER-ORDER showcase (#27): `map` and `filter` are define'd
        // functions whose first PARAMETER is a closure they CALL on each element
        // (`(f (car l))` / `(p (car l))`) - the symbol-head call resolves the
        // parameter to a `VClosure` in the value env and applies it via `apply-value`
        // (first-class functions as ARGUMENTS). `(print (map (lambda (x) (* x x))
        // (list 1 2 3 4)))` renders `(1 4 9 16)` and `(print (filter (lambda (x)
        // (< x 3)) (list 1 2 3 4)))` renders `(1 2)`. The arm then denotes the
        // UNPRINTED `(sum-list (map (lambda (x) (* x x)) (list 1 2 3 4)))` - a numeric
        // witness that map yields a real list `sum-list` walks = `1+4+9+16` =
        // `(VInt 30)`. Stdout is
        // `hello world3233\n25\n15\n2\n10\n1\n0\n1\n3\n(1 2 3)(1 (2 3) 4)(10 . 20)(1 2 . 3)(1 4 9 16)(1 2)`
        // and the exit code is `30`, proving the interpreter has first-class
        // functions (including closures passed AS ARGUMENTS to define'd functions),
        // can build (via the variadic `list` constructor) and walk pairs and linked
        // lists, can express recursive AND higher-order list algorithms, AND PRINTS a
        // list as `(...)`. All three imported `main`-less modules are copied alongside
        // so the `(import)` chain resolves.
        Case {
            name: "tl_eval",
            exit_code: 30,
            stdout: "hello world3233\n25\n15\n2\n10\n1\n0\n1\n3\n(1 2 3)(1 (2 3) 4)(10 . 20)(1 2 . 3)(1 4 9 16)(1 2)",
            deps: &["read.tl", "lex.tl", "token.tl"],
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
        // refs #42: Immutable scoped String -> i64 symbol table. A focused
        // functional API with head-first lookup, shadowing, and key equality
        // via `string-eq`. Exercises `defenum`, recursive `match`, `substring`,
        // and `string-append` as key builders. Stdout is the PASS lines from
        // each assertion; exit code is 0.
        Case {
            name: "sym_i64_env",
            exit_code: 0,
            stdout: "PASS: empty-miss\nPASS: single-hit-contains\nPASS: single-hit-value\nPASS: single-miss\nPASS: shadow-newest\nPASS: outer-preserved-a\nPASS: outer-no-b\nPASS: inner-sees-a\nPASS: inner-sees-b\nPASS: substring-key-hit\nPASS: append-key-hit\nPASS: chain-x\nPASS: chain-y\nPASS: chain-z\nAll sym-i64-env tests passed.\n",
            deps: &["sym_i64_env_core.tl"],
        },
        // refs #336: main-less selfhost text buffer utility. The driver checks
        // empty rendering, multi-chunk append order, repeated appends, and
        // buffer append before printing the joined text.
        Case {
            name: "text_buf",
            exit_code: 0,
            stdout: "left-right\n",
            deps: &["text_buf_core.tl"],
        },
    ];

    for case in cases {
        run_case(&case);
    }
}

#[test]
fn spmd_foreach_avx2_runs_when_host_supports_avx2() {
    #[cfg(not(any(target_arch = "x86", target_arch = "x86_64")))]
    {
        eprintln!("skipping AVX2 SPMD execution test on non-x86 host");
    }

    #[cfg(any(target_arch = "x86", target_arch = "x86_64"))]
    {
        if !std::is_x86_feature_detected!("avx2") {
            eprintln!("skipping AVX2 SPMD execution test because host CPU lacks AVX2");
            return;
        }

        let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        let source_path = manifest_dir
            .join("tests")
            .join("integration")
            .join("spmd_foreach.tl");
        let work_dir = manifest_dir
            .join("target")
            .join("integration-tests")
            .join("spmd_foreach_avx2");
        fs::create_dir_all(&work_dir).expect("create AVX2 SPMD test work dir");
        let work_path = work_dir.join("spmd_foreach.tl");
        fs::copy(&source_path, &work_path).expect("copy spmd_foreach.tl to work dir");

        let output = Command::new(env!("CARGO_BIN_EXE_typelisp"))
            .arg("run")
            .arg(&work_path)
            .arg("--backend-mode")
            .arg("avx2")
            .output()
            .expect("run typelisp AVX2 SPMD fixture");

        let stdout = String::from_utf8_lossy(&output.stdout);
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert_eq!(
            output.status.code(),
            Some(42),
            "AVX2 SPMD fixture exited unexpectedly\nstdout:\n{}\nstderr:\n{}",
            stdout,
            stderr
        );
        assert_eq!(stdout, "", "AVX2 SPMD fixture wrote stdout");
        assert_eq!(stderr, "", "AVX2 SPMD fixture wrote stderr");
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
            name: "format_doc_integration",
            exit_code: 42,
            stdout: "",
            deps: &["format_doc.tl"],
        },
        Case {
            name: "format_cst_integration",
            exit_code: 42,
            stdout: "",
            deps: &["format_cst.tl", "format_tokens.tl"],
        },
        Case {
            name: "format_core_integration",
            exit_code: 42,
            stdout: "",
            deps: &[
                "format_core.tl",
                "format_cst.tl",
                "format_tokens.tl",
                "format_doc.tl",
            ],
        },
        Case {
            name: "format_rules_integration",
            exit_code: 42,
            stdout: "",
            deps: &[
                "format_rules.tl",
                "format_cst.tl",
                "format_tokens.tl",
                "format_doc.tl",
            ],
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
            name: "global_initializer",
            exit_code: 120,
            stdout: "",
            deps: &[],
        },
        Case {
            name: "aggregate_globals",
            exit_code: 42,
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
            name: "function_pointer_values",
            exit_code: 42,
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
            name: "string_match",
            exit_code: 42,
            stdout: "",
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
        // refs #41, GAP (D): the zero-arg call form `(Ctor)` constructs a NULLARY
        // enum variant, also through the explicit compile -> as -> ld -> run
        // pipeline. `main` = code(Red)=1 + code(Green)=2 + code(RGB 9)=9 +
        // bias=30 = 42, proving `(Red)`/`(Green)` construct nullary variants while
        // the zero-arg function `(bias)` still calls.
        Case {
            name: "nullary_variant_call",
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
        // refs #228: monomorphic Maybe/Result convention, also through the
        // explicit compile -> as -> ld -> run pipeline.
        Case {
            name: "maybe_result",
            exit_code: 65,
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
        // Self-hosting M1 (#155/#156): the TypeLisp arithmetic emitter and
        // full-.s driver, also through the explicit compile -> as -> ld -> run
        // pipeline. It prints the complete program for `(+ 1 (* 2 3))`.
        Case {
            name: "tl_emit",
            exit_code: 0,
            stdout: TL_EMIT_PROGRAM_ASM,
            deps: &["emit_core.tl", "ast_types.tl", "sym_i64_env.tl"],
        },
        // Self-hosting M1 (#154/#173): Sexpr -> compiler AST parser, also
        // through the explicit compile -> as -> ld -> run pipeline.
        Case {
            name: "tl_ast",
            exit_code: 173,
            stdout: "",
            deps: &["ast_types.tl", "read.tl", "lex.tl", "token.tl"],
        },
        // Self-hosting (#27): the TypeLisp-syntax (s-expression) lexer - now with
        // string literals (`TStr`), char literals (`TChar`), and `;` line comments
        // - also exercised through the explicit compile -> as -> ld -> run
        // pipeline. The sample includes `#x'`, `#\n'`, `#\space'`, and
        // `#\newline'`; `main` verifies their decoded code sum, checks the
        // recoverable `lex-result` error path, and returns 12 tokens + 1 string
        // + 4 chars = 17.
        Case {
            name: "tl_lexer",
            exit_code: 17,
            stdout: "",
            deps: &["lex.tl", "token.tl"],
        },
        // Self-hosting (#27): the s-expression reader, also exercised through the
        // explicit compile -> as -> ld -> run pipeline. Reads
        // a nested sample into the recursive cons-cell `Sexpr` AST and folds it:
        // integer atoms sum to 42, string atoms count to 2, char atoms count to 4,
        // decoded char codes sum to 172, and recoverable reader diagnostics add 3,
        // so the result is 61.
        Case {
            name: "tl_reader",
            exit_code: 61,
            stdout: "",
            deps: &["lex.tl", "token.tl"],
        },
        // Self-hosting (#27): the s-expression evaluator with FIRST-CLASS
        // FUNCTIONS (`lambda` + CLOSURES), CONS PAIRS / LINKED LISTS, AND the
        // `pair?` / `null?` LIST PREDICATES - on top of variables, multi-binding
        // `let`, `if`, comparisons, the `begin` SEQUENCING special form, recursion,
        // multi-arg user functions, the tagged `(VInt/VStr/VClosure/VPair)` VALUE
        // domain, and the string ops - also exercised through the explicit
        // compile -> as -> ld -> run pipeline. It preserves the prior executed
        // recursion/string witness (`pow`, substring/string-append/int conversion,
        // `hello world3233\n`), adds two closure cases (immediate application ->
        // `25\n`, captured free variable -> `15\n`), and then the LIST-CONSTRUCTOR /
        // PREDICATE / RECURSIVE-LIST witness: `lst = (list 1 2 3)` (the variadic
        // `list` SPECIAL FORM, denoting the 3-element right-nested `(VPair ...)` chain
        // terminated by the `0` NIL sentinel) and `p = (cons 10 20)`, printing the
        // list's second element (`2\n`), the pair's car (`10\n`), then exercising the
        // predicates - `(pair? lst)` `1\n`, `(null? lst)` `0\n`, `(null? 0)` `1\n` -
        // and the recursive `(list-len lst)` `3\n`, THEN the RECURSIVE LIST PRINTER
        // (#27): `(print lst)` -> `(1 2 3)`, `(print (list 1 (list 2 3) 4))` ->
        // `(1 (2 3) 4)`, `(print p)` -> `(10 . 20)` (improper pair in dotted-pair
        // notation), and `(print (cons 1 (cons 2 3)))` -> `(1 2 . 3)`, all with no
        // trailing newline, THEN the HIGHER-ORDER showcase:
        // `map` / `filter` are define'd functions that CALL a closure-valued
        // parameter on each element, so `(print (map (lambda (x) (* x x))
        // (list 1 2 3 4)))` -> `(1 4 9 16)` and `(print (filter (lambda (x) (< x 3))
        // (list 1 2 3 4)))` -> `(1 2)`, before returning the unprinted
        // `(sum-list (map (lambda (x) (* x x)) (list 1 2 3 4)))` = `1+4+9+16` =
        // `(VInt 30)`. Stdout is
        // `hello world3233\n25\n15\n2\n10\n1\n0\n1\n3\n(1 2 3)(1 (2 3) 4)(10 . 20)(1 2 . 3)(1 4 9 16)(1 2)`
        // and the exit code is `30`. The reader (and transitively the lexer + token
        // model) is reused via the `main`-less `read.tl` import - including its
        // lower-level `read-form` cursor entry, which the program reader drives to
        // read all top-level forms; all three imported modules are copied alongside
        // so the imports resolve.
        Case {
            name: "tl_eval",
            exit_code: 30,
            stdout: "hello world3233\n25\n15\n2\n10\n1\n0\n1\n3\n(1 2 3)(1 (2 3) 4)(10 . 20)(1 2 . 3)(1 4 9 16)(1 2)",
            deps: &["read.tl", "lex.tl", "token.tl"],
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
        // refs #42: Immutable scoped String -> i64 symbol table through the
        // explicit compile -> as -> ld -> run pipeline.
        Case {
            name: "sym_i64_env",
            exit_code: 0,
            stdout: "PASS: empty-miss\nPASS: single-hit-contains\nPASS: single-hit-value\nPASS: single-miss\nPASS: shadow-newest\nPASS: outer-preserved-a\nPASS: outer-no-b\nPASS: inner-sees-a\nPASS: inner-sees-b\nPASS: substring-key-hit\nPASS: append-key-hit\nPASS: chain-x\nPASS: chain-y\nPASS: chain-z\nAll sym-i64-env tests passed.\n",
            deps: &["sym_i64_env_core.tl"],
        },
        // refs #336: selfhost text buffer utility through the explicit
        // compile -> as -> ld -> run pipeline.
        Case {
            name: "text_buf",
            exit_code: 0,
            stdout: "left-right\n",
            deps: &["text_buf_core.tl"],
        },
        // stdlib/string.tl: trim edge cases, contains, and replace through the
        // explicit compile -> as -> ld -> run pipeline.
        Case {
            name: "stdlib_string",
            exit_code: 42,
            stdout: "hello|\nhello|\nhello|\nfound\n|empty-left\n|empty-right\n|all-space\ncontains\nmissing\nhippo\nabx\n",
            deps: &["stdlib/string.tl"],
        },
        // stdlib/test.tl: shared TypeLisp-native assertion helpers. Passing
        // assertions are silent and preserve the caller's chosen result.
        Case {
            name: "stdlib_test",
            exit_code: 42,
            stdout: "",
            deps: &["stdlib/test.tl"],
        },
        // refs #335: selfhost parser from Sexpr into the real compiler AST.
        // The smoke parses a representative multi-declaration source string
        // with imports, structs, enums, externs, typed definitions, let,
        // arrays, match arms, and bracketed parameter syntax.
        Case {
            name: "compiler_parse_smoke",
            exit_code: 42,
            stdout: "",
            deps: &[
                "compiler_parse_core.tl",
                "compiler_ast_types.tl",
                "sym_i64_env.tl",
                "read.tl",
                "lex.tl",
                "token.tl",
            ],
        },
        // refs #405/#423: selfhost top-level symbol table plus variant/field
        // registries over the real compiler AST. The smoke parses a
        // representative source, builds deterministic value/type declaration
        // tables and enum/struct metadata, checks lookup handles, and verifies
        // duplicate detection stays recoverable.
        Case {
            name: "compiler_symbols_smoke",
            exit_code: 42,
            stdout: "",
            deps: &[
                "compiler_symbols.tl",
                "compiler_parse_core.tl",
                "compiler_ast_types.tl",
                "sym_i64_env.tl",
                "read.tl",
                "lex.tl",
                "token.tl",
            ],
        },
        // refs #426/#444/#441: selfhost typechecker pass over compiler AST.
        // The smoke parses representative scalar, aggregate, and nominal sources,
        // checks constructors, `struct-get`, match payload binding, and recoverable
        // negative diagnostics.
        Case {
            name: "compiler_typecheck_smoke",
            exit_code: 42,
            stdout: "",
            deps: &[
                "compiler_typecheck.tl",
                "compiler_symbols.tl",
                "compiler_parse_core.tl",
                "compiler_ast_types.tl",
                "sym_i64_env.tl",
                "read.tl",
                "lex.tl",
                "token.tl",
            ],
        },
        // refs #446: selfhost compiler IR and first scalar lowerer. The smoke
        // parses, symbol-checks, typechecks, and lowers a small program with a
        // direct call, let/set!, while, and if into a deterministic IR summary.
        Case {
            name: "compiler_lower_smoke",
            exit_code: 42,
            stdout: "",
            deps: &[
                "compiler_lower.tl",
                "compiler_ir_types.tl",
                "compiler_typecheck.tl",
                "compiler_symbols.tl",
                "compiler_parse_core.tl",
                "compiler_ast_types.tl",
                "sym_i64_env.tl",
                "read.tl",
                "lex.tl",
                "token.tl",
            ],
        },
        // refs #553: selfhost CompilerIr liveness analysis over straight-line,
        // branching, and phi-input control-flow shapes.
        Case {
            name: "compiler_liveness_smoke",
            exit_code: 42,
            stdout: "",
            deps: &[
                "compiler_liveness.tl",
                "compiler_ir_types.tl",
                "compiler_ast_types.tl",
            ],
        },
        // refs #543: selfhost optimizer pass framework + scalar constant folding.
        // The smoke folds a constant `BinOp` into a `Mov` literal and checks the
        // arithmetic instruction count drops while the folded value is correct.
        Case {
            name: "compiler_optimize_smoke",
            exit_code: 42,
            stdout: "",
            deps: &[
                "compiler_optimize.tl",
                "compiler_ir_types.tl",
                "compiler_ast_types.tl",
            ],
        },
        // refs #447: first selfhost backend emitter over the real compiler IR.
        // The smoke parses, typechecks, lowers, emits deterministic Linux x86_64
        // assembly text, and verifies representative labels/instructions.
        Case {
            name: "compiler_backend_smoke",
            exit_code: 42,
            stdout: "",
            deps: &[
                "compiler_backend.tl",
                "compiler_lower.tl",
                "compiler_ir_types.tl",
                "compiler_typecheck.tl",
                "compiler_symbols.tl",
                "compiler_parse_core.tl",
                "compiler_ast_types.tl",
                "sym_i64_env.tl",
                "text_buf.tl",
                "read.tl",
                "lex.tl",
                "token.tl",
            ],
        },
        // refs #387: selfhost doc comment extraction over TypeLisp source.
        // The smoke checks module docs, supported item docs, ignored ordinary
        // comments, blank-line clearing, and unattached EOF docs.
        Case {
            name: "doc_extract_smoke",
            exit_code: 42,
            stdout: "",
            deps: &["doc_extract.tl", "format_tokens.tl"],
        },
        // refs #388: selfhost Markdown rendering over extracted docs. The
        // smoke checks module docs, globals, functions, externs, enums,
        // variants, structs, fields, Markdown escaping, anchors, and the
        // predictable empty-model rendering.
        Case {
            name: "doc_render_smoke",
            exit_code: 42,
            stdout: "",
            deps: &["doc_render.tl", "doc_extract.tl", "format_tokens.tl"],
        },
    ];

    for case in cases {
        run_case_explicit_build(&case);
    }
}

#[test]
fn selfhost_backend_runtime_helpers_emit_assemble_link_and_run() {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let fixture_path = manifest_dir
        .join("selfhost")
        .join("compiler_backend_runtime_fixture.tl");
    let work_dir = manifest_dir
        .join("target")
        .join("integration-tests")
        .join("compiler_backend_runtime_helpers");
    fs::create_dir_all(&work_dir).expect("create backend runtime helper test work dir");

    let asm_path = work_dir.join("runtime_helpers.s");
    let obj_path = work_dir.join("runtime_helpers.o");
    let bin_path = work_dir.join("runtime_helpers");

    let output = Command::new(env!("CARGO_BIN_EXE_typelisp"))
        .arg("run")
        .arg(&fixture_path)
        .arg("--")
        .arg(&asm_path)
        .output()
        .expect("run compiler_backend_runtime_fixture");
    assert_eq!(
        output.status.code(),
        Some(0),
        "runtime fixture failed\nstdout:\n{}\nstderr:\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );

    let asm = fs::read_to_string(&asm_path).expect("read runtime helper fixture assembly");
    for snippet in [
        ".globl tl_alloc\n",
        "\ntl_alloc:\n",
        ".globl tl_oob_abort\n",
        "\ntl_oob_abort:\n",
        ".globl tl_substring\n",
        "\ntl_substring:\n",
        ".globl tl_string_concat\n",
        "\ntl_string_concat:\n",
        ".L_tl_substring_copy_loop:\n",
        ".L_tl_string_concat_copy_b:\n",
        "    call tl_alloc\n",
    ] {
        assert!(
            asm.contains(snippet),
            "runtime helper assembly missing {:?}:\n{}",
            snippet,
            asm
        );
    }
    for helper in [
        ".extern tl_alloc\n",
        ".extern tl_oob_abort\n",
        ".extern tl_substring\n",
        ".extern tl_string_concat\n",
    ] {
        assert!(
            !asm.contains(helper),
            "runtime helper should be defined inline, not extern: {helper}\n{asm}"
        );
    }

    let status = Command::new("as")
        .arg(&asm_path)
        .arg("-o")
        .arg(&obj_path)
        .status()
        .expect("assemble runtime helper fixture output");
    assert!(status.success(), "assembling runtime helper output failed");

    let status = Command::new("ld")
        .arg(&obj_path)
        .arg("-o")
        .arg(&bin_path)
        .status()
        .expect("link runtime helper fixture output");
    assert!(status.success(), "linking runtime helper output failed");

    let output = Command::new(&bin_path)
        .output()
        .expect("run runtime helper fixture binary");
    assert_eq!(
        output.status.code(),
        Some(42),
        "runtime helper binary exited unexpectedly\nstdout:\n{}\nstderr:\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
}

#[test]
fn selfhost_compiler_driver_emits_deterministic_runnable_assembly() {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let selfhost_dir = manifest_dir.join("selfhost");
    let source_path = selfhost_dir.join("compiler_driver.tl");
    let work_dir = manifest_dir
        .join("target")
        .join("integration-tests")
        .join("compiler_driver_file_to_file");
    fs::create_dir_all(&work_dir).expect("create compiler_driver file-to-file test work dir");

    let work_path = work_dir.join("compiler_driver.tl");
    fs::copy(&source_path, &work_path).expect("copy compiler_driver.tl to work dir");
    copy_case_deps(
        &manifest_dir,
        &selfhost_dir,
        &work_dir,
        &[
            "compiler_driver_core.tl",
            "compiler_backend.tl",
            "compiler_optimize.tl",
            "compiler_lower.tl",
            "compiler_ir_types.tl",
            "compiler_typecheck.tl",
            "compiler_symbols.tl",
            "compiler_load.tl",
            "compiler_parse_core.tl",
            "compiler_ast_types.tl",
            "sym_i64_env.tl",
            "text_buf.tl",
            "read.tl",
            "lex.tl",
            "token.tl",
        ],
    );

    let driver_bin = work_dir.join("compiler-driver");
    let build = Command::new(env!("CARGO_BIN_EXE_typelisp"))
        .arg("build")
        .arg(&work_path)
        .arg("-o")
        .arg(&driver_bin)
        .output()
        .expect("build compiler_driver.tl");
    assert!(
        build.status.success(),
        "compiler_driver build failed\nstdout:\n{}\nstderr:\n{}",
        String::from_utf8_lossy(&build.stdout),
        String::from_utf8_lossy(&build.stderr)
    );
    assert!(
        driver_bin.exists(),
        "compiler_driver build did not write binary"
    );

    let input_path = work_dir.join("input.tl");
    let helper_path = work_dir.join("helper.tl");
    let shared_path = work_dir.join("shared.tl");
    let asm_path = work_dir.join("generated.s");
    let asm_again_path = work_dir.join("generated-again.s");
    let obj_path = work_dir.join("generated.o");
    let bin_path = work_dir.join("generated");
    fs::write(&shared_path, "(define shared : i64 2)\n")
        .expect("write compiler_driver shared fixture");
    fs::write(
        &helper_path,
        "(import \"shared.tl\")\n(define (helper) : i64 (+ 38 shared))\n",
    )
    .expect("write compiler_driver imported fixture");
    fs::write(
        &input_path,
        "(import \"helper.tl\")\n(import \"shared.tl\")\n(define (main) : i64 (+ (helper) shared))\n",
    )
    .expect("write compiler_driver input fixture");

    for output_path in [&asm_path, &asm_again_path] {
        let run = Command::new(&driver_bin)
            .arg(&input_path)
            .arg(output_path)
            .output()
            .expect("run compiler_driver binary");
        assert_eq!(
            run.status.code(),
            Some(0),
            "compiler_driver exited unexpectedly\nstdout:\n{}\nstderr:\n{}",
            String::from_utf8_lossy(&run.stdout),
            String::from_utf8_lossy(&run.stderr)
        );
        assert_eq!(
            String::from_utf8_lossy(&run.stdout),
            "",
            "compiler_driver wrote stdout"
        );
        assert_eq!(
            String::from_utf8_lossy(&run.stderr),
            "",
            "compiler_driver wrote stderr"
        );
    }

    let asm = fs::read_to_string(&asm_path).expect("read compiler_driver generated assembly");
    let asm_again =
        fs::read_to_string(&asm_again_path).expect("read repeated compiler_driver assembly");
    assert_eq!(asm_again, asm, "compiler_driver output changed across runs");
    for snippet in [
        ".text\n.globl _start\n",
        "_tl_shared:\n",
        "_tl_helper:\n",
        "main:\n",
        "    call _tl_helper\n",
        "_tl_shared(%rip)",
        "_start:\n    call main\n",
    ] {
        assert!(
            asm.contains(snippet),
            "compiler_driver generated assembly missing {:?}:\n{}",
            snippet,
            asm
        );
    }

    let status = Command::new("as")
        .arg(&asm_path)
        .arg("-o")
        .arg(&obj_path)
        .status()
        .expect("run assembler on compiler_driver output");
    assert!(status.success(), "assembling compiler_driver output failed");

    let status = Command::new("ld")
        .arg(&obj_path)
        .arg("-o")
        .arg(&bin_path)
        .arg("-dynamic-linker")
        .arg("/lib64/ld-linux-x86-64.so.2")
        .arg("-lc")
        .status()
        .expect("run linker on compiler_driver output");
    assert!(status.success(), "linking compiler_driver output failed");

    let output = Command::new(&bin_path)
        .output()
        .expect("run binary assembled from compiler_driver output");
    assert_eq!(
        output.status.code(),
        Some(42),
        "compiler_driver output program exited unexpectedly\nstdout:\n{}\nstderr:\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(
        String::from_utf8_lossy(&output.stdout),
        "",
        "compiler_driver output program stdout"
    );
    assert_eq!(
        String::from_utf8_lossy(&output.stderr),
        "",
        "compiler_driver output program stderr"
    );
}

#[test]
fn selfhost_check_driver_reports_success_and_errors() {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let selfhost_dir = manifest_dir.join("selfhost");
    let source_path = selfhost_dir.join("check.tl");
    let work_dir = manifest_dir
        .join("target")
        .join("integration-tests")
        .join("selfhost_check_driver");
    fs::create_dir_all(&work_dir).expect("create selfhost check driver test work dir");

    let work_path = work_dir.join("check.tl");
    fs::copy(&source_path, &work_path).expect("copy check.tl to work dir");
    copy_case_deps(
        &manifest_dir,
        &selfhost_dir,
        &work_dir,
        &[
            "compiler_load.tl",
            "compiler_typecheck.tl",
            "compiler_symbols.tl",
            "compiler_parse_core.tl",
            "compiler_ast_types.tl",
            "sym_i64_env.tl",
            "read.tl",
            "lex.tl",
            "token.tl",
        ],
    );

    let driver_bin = work_dir.join("selfhost-check");
    let build = Command::new(env!("CARGO_BIN_EXE_typelisp"))
        .arg("build")
        .arg(&work_path)
        .arg("-o")
        .arg(&driver_bin)
        .output()
        .expect("build check.tl");
    assert!(
        build.status.success(),
        "check.tl build failed\nstdout:\n{}\nstderr:\n{}",
        String::from_utf8_lossy(&build.stdout),
        String::from_utf8_lossy(&build.stderr)
    );

    fs::write(work_dir.join("lib.tl"), "(define imported : i64 42)\n")
        .expect("write selfhost check import");
    let ok_path = work_dir.join("ok.tl");
    fs::write(
        &ok_path,
        "(import \"lib.tl\")\n(define (main) : i64 imported)\n",
    )
    .expect("write selfhost check success fixture");
    let ok = Command::new(&driver_bin)
        .arg(&ok_path)
        .output()
        .expect("run selfhost check success fixture");
    assert_eq!(
        ok.status.code(),
        Some(0),
        "selfhost check success exited unexpectedly\nstdout:\n{}\nstderr:\n{}",
        String::from_utf8_lossy(&ok.stdout),
        String::from_utf8_lossy(&ok.stderr)
    );
    assert_eq!(
        String::from_utf8_lossy(&ok.stdout),
        "",
        "selfhost check success wrote stdout"
    );
    assert_eq!(
        String::from_utf8_lossy(&ok.stderr),
        "",
        "selfhost check success wrote stderr"
    );

    let type_error_path = work_dir.join("type_error.tl");
    fs::write(&type_error_path, "(define (main) : i64 true)\n")
        .expect("write selfhost check type error fixture");
    let type_error = Command::new(&driver_bin)
        .arg(&type_error_path)
        .output()
        .expect("run selfhost check type error fixture");
    assert_eq!(type_error.status.code(), Some(1));
    assert_eq!(String::from_utf8_lossy(&type_error.stdout), "");
    assert!(
        String::from_utf8_lossy(&type_error.stderr).contains("typecheck: return type mismatch"),
        "type error stderr:\n{}",
        String::from_utf8_lossy(&type_error.stderr)
    );

    let parse_error_path = work_dir.join("parse_error.tl");
    fs::write(&parse_error_path, "(define (main) : i64\n")
        .expect("write selfhost check parse error fixture");
    let parse_error = Command::new(&driver_bin)
        .arg(&parse_error_path)
        .output()
        .expect("run selfhost check parse error fixture");
    assert_eq!(parse_error.status.code(), Some(1));
    assert_eq!(String::from_utf8_lossy(&parse_error.stdout), "");
    let parse_stderr = String::from_utf8_lossy(&parse_error.stderr);
    assert!(
        parse_stderr.contains("reader:") || parse_stderr.contains("parse:"),
        "parse error stderr:\n{}",
        parse_stderr
    );

    let load_error_path = work_dir.join("load_error.tl");
    fs::write(
        &load_error_path,
        "(import \"missing.tl\")\n(define (main) : i64 0)\n",
    )
    .expect("write selfhost check load error fixture");
    let load_error = Command::new(&driver_bin)
        .arg(&load_error_path)
        .output()
        .expect("run selfhost check load error fixture");
    assert_eq!(load_error.status.code(), Some(1));
    assert_eq!(String::from_utf8_lossy(&load_error.stdout), "");
    assert!(
        String::from_utf8_lossy(&load_error.stderr).contains("compiler-load: cannot read import"),
        "load error stderr:\n{}",
        String::from_utf8_lossy(&load_error.stderr)
    );

    let stdlib_reject = Command::new(&driver_bin)
        .arg(&ok_path)
        .arg("--stdlib-root")
        .arg(&work_dir)
        .output()
        .expect("run selfhost check stdlib-root rejection");
    assert_eq!(stdlib_reject.status.code(), Some(1));
    assert_eq!(String::from_utf8_lossy(&stdlib_reject.stdout), "");
    assert!(
        String::from_utf8_lossy(&stdlib_reject.stderr)
            .contains("selfhost-check: --stdlib-root is not supported yet"),
        "stdlib-root stderr:\n{}",
        String::from_utf8_lossy(&stdlib_reject.stderr)
    );
}

#[test]
fn tl_emit_printed_program_assembles_links_and_exits_7() {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let selfhost_dir = manifest_dir.join("selfhost");
    let source_path = selfhost_dir.join("emit.tl");
    let work_dir = manifest_dir
        .join("target")
        .join("integration-tests")
        .join("tl_emit_printed_program");
    fs::create_dir_all(&work_dir).expect("create tl_emit printed-program test work dir");

    let work_path = work_dir.join("emit.tl");
    fs::copy(&source_path, &work_path).expect("copy emit.tl to work dir");
    fs::copy(
        selfhost_dir.join("ast_types.tl"),
        work_dir.join("ast_types.tl"),
    )
    .expect("copy ast_types.tl to work dir");
    fs::copy(
        selfhost_dir.join("emit_core.tl"),
        work_dir.join("emit_core.tl"),
    )
    .expect("copy emit_core.tl to work dir");
    fs::copy(
        selfhost_dir.join("sym_i64_env.tl"),
        work_dir.join("sym_i64_env.tl"),
    )
    .expect("copy sym_i64_env.tl to work dir");

    let output = Command::new(env!("CARGO_BIN_EXE_typelisp"))
        .arg("run")
        .arg(&work_path)
        .output()
        .expect("run tl_emit");

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert_eq!(
        output.status.code(),
        Some(0),
        "tl_emit driver exited unexpectedly\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr,
    );
    assert_eq!(
        stdout, TL_EMIT_PROGRAM_ASM,
        "tl_emit printed program differed\nstderr:\n{}",
        stderr,
    );

    let asm_path = work_dir.join("printed.s");
    let obj_path = work_dir.join("printed.o");
    let bin_path = work_dir.join("printed");
    fs::write(&asm_path, &output.stdout).expect("write printed assembly");

    let status = Command::new("as")
        .arg(&asm_path)
        .arg("-o")
        .arg(&obj_path)
        .status()
        .expect("run assembler on printed tl_emit output");
    assert!(status.success(), "assembling printed tl_emit output failed");

    let status = Command::new("ld")
        .arg(&obj_path)
        .arg("-o")
        .arg(&bin_path)
        .status()
        .expect("run linker on printed tl_emit output");
    assert!(status.success(), "linking printed tl_emit output failed");

    let output = Command::new(&bin_path)
        .output()
        .expect("run binary assembled from printed tl_emit output");
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert_eq!(
        output.status.code(),
        Some(7),
        "printed tl_emit program exited unexpectedly\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr,
    );
    assert_eq!(stdout, "", "printed tl_emit program wrote stdout");
}

#[test]
fn tl_emit_let_printed_programs_assemble_link_and_exit_expected() {
    let cases = [
        (
            "let_7",
            r#"(ELet "x"
  (EBin (OpMul) (EInt 2) (EInt 3))
  (EBin (OpAdd) (EVar "x") (EInt 1)))"#,
            7,
            &["    movq %rax, -8(%rbp)\n", "    movq -8(%rbp), %rax\n"][..],
        ),
        (
            "let_square_25",
            r#"(ELet "x"
  (EInt 5)
  (EBin (OpMul) (EVar "x") (EVar "x")))"#,
            25,
            &["    movq %rax, -8(%rbp)\n", "    movq -8(%rbp), %rax\n"][..],
        ),
        (
            "nested_let_6",
            r#"(ELet "x"
  (EInt 2)
  (ELet "y"
    (EInt 3)
    (EBin (OpMul) (EVar "x") (EVar "y"))))"#,
            6,
            &[
                "    movq %rax, -8(%rbp)\n",
                "    movq %rax, -16(%rbp)\n",
                "    movq -8(%rbp), %rax\n",
                "    movq -16(%rbp), %rax\n",
            ][..],
        ),
    ];

    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let selfhost_dir = manifest_dir.join("selfhost");
    let root_dir = manifest_dir
        .join("target")
        .join("integration-tests")
        .join("tl_emit_let_printed_programs");

    for (name, expr, exit_code, snippets) in cases {
        let work_dir = root_dir.join(name);
        fs::create_dir_all(&work_dir).expect("create tl_emit let test work dir");

        for dep in ["emit_core.tl", "ast_types.tl", "sym_i64_env.tl"] {
            fs::copy(selfhost_dir.join(dep), work_dir.join(dep))
                .expect("copy imported emitter module to work dir");
        }

        let source = format!(
            "(import \"emit_core.tl\")\n\n\
             (define (sample) : Expr\n  {})\n\n\
             (define (main) : unit\n  (print-string (emit-program (sample))))\n",
            expr
        );
        let work_path = work_dir.join("driver.tl");
        fs::write(&work_path, source).expect("write tl_emit let driver");

        let output = Command::new(env!("CARGO_BIN_EXE_typelisp"))
            .arg("run")
            .arg(&work_path)
            .output()
            .expect("run tl_emit let driver");

        let stdout = String::from_utf8_lossy(&output.stdout);
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert_eq!(
            output.status.code(),
            Some(0),
            "{} driver exited unexpectedly\nstdout:\n{}\nstderr:\n{}",
            name,
            stdout,
            stderr,
        );
        assert!(
            stdout.contains("    sub $16, %rsp\n"),
            "{} did not reserve the aligned let frame:\n{}",
            name,
            stdout,
        );
        assert!(
            stdout.contains("    add $16, %rsp\n"),
            "{} did not restore the aligned let frame:\n{}",
            name,
            stdout,
        );
        for snippet in snippets {
            assert!(
                stdout.contains(snippet),
                "{} emitted assembly missing {:?}:\n{}",
                name,
                snippet,
                stdout,
            );
        }

        let asm_path = work_dir.join("printed.s");
        let obj_path = work_dir.join("printed.o");
        let bin_path = work_dir.join("printed");
        fs::write(&asm_path, &output.stdout).expect("write printed assembly");

        let status = Command::new("as")
            .arg(&asm_path)
            .arg("-o")
            .arg(&obj_path)
            .status()
            .expect("run assembler on printed tl_emit let output");
        assert!(status.success(), "{} assembly failed", name);

        let status = Command::new("ld")
            .arg(&obj_path)
            .arg("-o")
            .arg(&bin_path)
            .status()
            .expect("run linker on printed tl_emit let output");
        assert!(status.success(), "{} linking failed", name);

        let output = Command::new(&bin_path)
            .output()
            .expect("run binary assembled from printed tl_emit let output");
        let stdout = String::from_utf8_lossy(&output.stdout);
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert_eq!(
            output.status.code(),
            Some(exit_code),
            "{} printed program exited unexpectedly\nstdout:\n{}\nstderr:\n{}",
            name,
            stdout,
            stderr,
        );
        assert_eq!(stdout, "", "{} printed program wrote stdout", name);
    }
}

#[test]
fn tl_emit_if_printed_programs_assemble_link_and_exit_expected() {
    let cases = [
        (
            "if_lt_true_10",
            r#"(EIf
  (EBin (OpLt) (EInt 1) (EInt 2))
  (EInt 10)
  (EInt 20))"#,
            10,
            &[
                "    cmpq %rcx, %rax\n",
                "    setl %al\n",
                "    cmpq $0, %rax\n",
                "    je .Lelse_",
                "    jmp .Lend_",
                ".Lelse_",
                ".Lend_",
            ][..],
        ),
        (
            "if_eq_false_20",
            r#"(EIf
  (EBin (OpEq) (EInt 1) (EInt 2))
  (EInt 10)
  (EInt 20))"#,
            20,
            &[
                "    cmpq %rcx, %rax\n",
                "    sete %al\n",
                "    cmpq $0, %rax\n",
                "    je .Lelse_",
                "    jmp .Lend_",
            ][..],
        ),
        (
            "if_lt_false_20",
            r#"(EIf
  (EBin (OpLt) (EInt 2) (EInt 1))
  (EInt 10)
  (EInt 20))"#,
            20,
            &["    setl %al\n", "    cmpq $0, %rax\n"][..],
        ),
        (
            "nested_if_7",
            r#"(EIf
  (EBin (OpLt) (EInt 1) (EInt 2))
  (EIf
    (EBin (OpEq) (EInt 3) (EInt 3))
    (EInt 7)
    (EInt 8))
  (EInt 20))"#,
            7,
            &["    setl %al\n", "    sete %al\n", ".Lelse_2", ".Lend_3"][..],
        ),
        (
            "if_in_let_1",
            r#"(ELet "x"
  (EInt 5)
  (EIf
    (EBin (OpLt) (EVar "x") (EInt 10))
    (EInt 1)
    (EInt 0)))"#,
            1,
            &[
                "    sub $16, %rsp\n",
                "    movq %rax, -8(%rbp)\n",
                "    movq -8(%rbp), %rax\n",
                "    setl %al\n",
                "    add $16, %rsp\n",
            ][..],
        ),
        // refs #173: M2(a) comparison operators. The emitter follows the same
        // cmpq %rcx, %rax convention (left in %rax, right in %rcx, so the flags
        // reflect left - right) as OpLt/OpEq, with setle/setg/setge/setne. These
        // exercise both the true (10) and false (20) branch of each new operator,
        // proving `>` / `<=` are NOT inverted.
        (
            "if_le_true_10",
            r#"(EIf
  (EBin (OpLe) (EInt 2) (EInt 2))
  (EInt 10)
  (EInt 20))"#,
            10,
            &["    cmpq %rcx, %rax\n", "    setle %al\n"][..],
        ),
        (
            "if_le_false_20",
            r#"(EIf
  (EBin (OpLe) (EInt 3) (EInt 2))
  (EInt 10)
  (EInt 20))"#,
            20,
            &["    setle %al\n"][..],
        ),
        (
            "if_gt_true_10",
            r#"(EIf
  (EBin (OpGt) (EInt 3) (EInt 2))
  (EInt 10)
  (EInt 20))"#,
            10,
            &["    cmpq %rcx, %rax\n", "    setg %al\n"][..],
        ),
        (
            "if_gt_false_20",
            r#"(EIf
  (EBin (OpGt) (EInt 2) (EInt 3))
  (EInt 10)
  (EInt 20))"#,
            20,
            &["    setg %al\n"][..],
        ),
        (
            "if_ge_true_10",
            r#"(EIf
  (EBin (OpGe) (EInt 3) (EInt 3))
  (EInt 10)
  (EInt 20))"#,
            10,
            &["    cmpq %rcx, %rax\n", "    setge %al\n"][..],
        ),
        (
            "if_ge_false_20",
            r#"(EIf
  (EBin (OpGe) (EInt 2) (EInt 3))
  (EInt 10)
  (EInt 20))"#,
            20,
            &["    setge %al\n"][..],
        ),
        (
            "if_ne_true_10",
            r#"(EIf
  (EBin (OpNe) (EInt 1) (EInt 2))
  (EInt 10)
  (EInt 20))"#,
            10,
            &["    cmpq %rcx, %rax\n", "    setne %al\n"][..],
        ),
        (
            "if_ne_false_20",
            r#"(EIf
  (EBin (OpNe) (EInt 2) (EInt 2))
  (EInt 10)
  (EInt 20))"#,
            20,
            &["    setne %al\n"][..],
        ),
    ];

    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let selfhost_dir = manifest_dir.join("selfhost");
    let root_dir = manifest_dir
        .join("target")
        .join("integration-tests")
        .join("tl_emit_if_printed_programs");

    for (name, expr, exit_code, snippets) in cases {
        let work_dir = root_dir.join(name);
        fs::create_dir_all(&work_dir).expect("create tl_emit if test work dir");

        for dep in ["emit_core.tl", "ast_types.tl", "sym_i64_env.tl"] {
            fs::copy(selfhost_dir.join(dep), work_dir.join(dep))
                .expect("copy imported emitter module to work dir");
        }

        let source = format!(
            "(import \"emit_core.tl\")\n\n\
             (define (sample) : Expr\n  {})\n\n\
             (define (main) : unit\n  (print-string (emit-program (sample))))\n",
            expr
        );
        let work_path = work_dir.join("driver.tl");
        fs::write(&work_path, source).expect("write tl_emit if driver");

        let output = Command::new(env!("CARGO_BIN_EXE_typelisp"))
            .arg("run")
            .arg(&work_path)
            .output()
            .expect("run tl_emit if driver");

        let stdout = String::from_utf8_lossy(&output.stdout);
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert_eq!(
            output.status.code(),
            Some(0),
            "{} driver exited unexpectedly\nstdout:\n{}\nstderr:\n{}",
            name,
            stdout,
            stderr,
        );
        for snippet in snippets {
            assert!(
                stdout.contains(snippet),
                "{} emitted assembly missing {:?}:\n{}",
                name,
                snippet,
                stdout,
            );
        }

        let asm_path = work_dir.join("printed.s");
        let obj_path = work_dir.join("printed.o");
        let bin_path = work_dir.join("printed");
        fs::write(&asm_path, &output.stdout).expect("write printed assembly");

        let status = Command::new("as")
            .arg(&asm_path)
            .arg("-o")
            .arg(&obj_path)
            .status()
            .expect("run assembler on printed tl_emit if output");
        assert!(status.success(), "{} assembly failed", name);

        let status = Command::new("ld")
            .arg(&obj_path)
            .arg("-o")
            .arg(&bin_path)
            .status()
            .expect("run linker on printed tl_emit if output");
        assert!(status.success(), "{} linking failed", name);

        let output = Command::new(&bin_path)
            .output()
            .expect("run binary assembled from printed tl_emit if output");
        let stdout = String::from_utf8_lossy(&output.stdout);
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert_eq!(
            output.status.code(),
            Some(exit_code),
            "{} printed program exited unexpectedly\nstdout:\n{}\nstderr:\n{}",
            name,
            stdout,
            stderr,
        );
        assert_eq!(stdout, "", "{} printed program wrote stdout", name);
    }
}

#[test]
fn tl_emit_comparison_printed_programs_assemble_link_and_exit_expected() {
    let cases = [
        (
            "le_equal_true",
            r#"(EBin (OpLe) (EInt 3) (EInt 3))"#,
            1,
            "    setle %al\n",
        ),
        (
            "le_false",
            r#"(EBin (OpLe) (EInt 4) (EInt 3))"#,
            0,
            "    setle %al\n",
        ),
        (
            "gt_true",
            r#"(EBin (OpGt) (EInt 5) (EInt 2))"#,
            1,
            "    setg %al\n",
        ),
        (
            "gt_false",
            r#"(EBin (OpGt) (EInt 2) (EInt 5))"#,
            0,
            "    setg %al\n",
        ),
        (
            "ge_false",
            r#"(EBin (OpGe) (EInt 2) (EInt 5))"#,
            0,
            "    setge %al\n",
        ),
        (
            "ge_equal_true",
            r#"(EBin (OpGe) (EInt 5) (EInt 5))"#,
            1,
            "    setge %al\n",
        ),
        (
            "ne_equal_false",
            r#"(EBin (OpNe) (EInt 7) (EInt 7))"#,
            0,
            "    setne %al\n",
        ),
        (
            "ne_true",
            r#"(EBin (OpNe) (EInt 7) (EInt 8))"#,
            1,
            "    setne %al\n",
        ),
    ];

    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let selfhost_dir = manifest_dir.join("selfhost");
    let root_dir = manifest_dir
        .join("target")
        .join("integration-tests")
        .join("tl_emit_comparison_printed_programs");

    for (name, expr, exit_code, setcc) in cases {
        let work_dir = root_dir.join(name);
        fs::create_dir_all(&work_dir).expect("create tl_emit comparison test work dir");

        for dep in ["emit_core.tl", "ast_types.tl", "sym_i64_env.tl"] {
            fs::copy(selfhost_dir.join(dep), work_dir.join(dep))
                .expect("copy imported emitter module to work dir");
        }

        let source = format!(
            "(import \"emit_core.tl\")\n\n\
             (define (sample) : Expr\n  {})\n\n\
             (define (main) : unit\n  (print-string (emit-program (sample))))\n",
            expr
        );
        let work_path = work_dir.join("driver.tl");
        fs::write(&work_path, source).expect("write tl_emit comparison driver");

        let output = Command::new(env!("CARGO_BIN_EXE_typelisp"))
            .arg("run")
            .arg(&work_path)
            .output()
            .expect("run tl_emit comparison driver");

        let stdout = String::from_utf8_lossy(&output.stdout);
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert_eq!(
            output.status.code(),
            Some(0),
            "{} driver exited unexpectedly\nstdout:\n{}\nstderr:\n{}",
            name,
            stdout,
            stderr,
        );
        for snippet in ["    cmpq %rcx, %rax\n", setcc, "    movzbq %al, %rax\n"] {
            assert!(
                stdout.contains(snippet),
                "{} emitted assembly missing {:?}:\n{}",
                name,
                snippet,
                stdout,
            );
        }

        let asm_path = work_dir.join("printed.s");
        let obj_path = work_dir.join("printed.o");
        let bin_path = work_dir.join("printed");
        fs::write(&asm_path, &output.stdout).expect("write printed assembly");

        let status = Command::new("as")
            .arg(&asm_path)
            .arg("-o")
            .arg(&obj_path)
            .status()
            .expect("run assembler on printed tl_emit comparison output");
        assert!(status.success(), "{} assembly failed", name);

        let status = Command::new("ld")
            .arg(&obj_path)
            .arg("-o")
            .arg(&bin_path)
            .status()
            .expect("run linker on printed tl_emit comparison output");
        assert!(status.success(), "{} linking failed", name);

        let output = Command::new(&bin_path)
            .output()
            .expect("run binary assembled from printed tl_emit comparison output");
        let stdout = String::from_utf8_lossy(&output.stdout);
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert_eq!(
            output.status.code(),
            Some(exit_code),
            "{} printed program exited unexpectedly\nstdout:\n{}\nstderr:\n{}",
            name,
            stdout,
            stderr,
        );
        assert_eq!(stdout, "", "{} printed program wrote stdout", name);
    }
}

#[test]
fn tl_emit_string_printed_programs_assemble_link_and_stdout_expected() {
    let cases = [
        (
            "print_hello_newline",
            r#"(EPrint (EStr "hello\n"))"#,
            0,
            "hello\n",
            &[
                "    .section .rodata\n",
                ".Lstr_0:\n",
                ".string \"hello\\n\"",
                "    leaq .Lstr_0(%rip), %rsi\n",
                "    movq $6, %rdx\n",
                "    syscall\n",
                "    movq $0, %rax\n",
            ][..],
        ),
        (
            "print_then_exit_7",
            r#"(ELet "_" (EPrint (EStr "side\n")) (EInt 7))"#,
            7,
            "side\n",
            &[
                ".Lstr_0:\n",
                ".string \"side\\n\"",
                "    movq $5, %rdx\n",
                "    movq $7, %rax\n",
            ][..],
        ),
        (
            "print_quote_backslash",
            r#"(EPrint (EStr "q\"b\\c"))"#,
            0,
            "q\"b\\c",
            &[
                ".Lstr_0:\n",
                ".string \"q\\\"b\\\\c\"",
                "    movq $5, %rdx\n",
            ][..],
        ),
        (
            "print_two_distinct_literals",
            r#"(ELet "_" (EPrint (EStr "a")) (ELet "__" (EPrint (EStr "b")) (EInt 0)))"#,
            0,
            "ab",
            &[
                ".Lstr_0:\n    .string \"a\"\n",
                ".Lstr_1:\n    .string \"b\"\n",
                "    leaq .Lstr_0(%rip), %rsi\n",
                "    leaq .Lstr_1(%rip), %rsi\n",
            ][..],
        ),
    ];

    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let selfhost_dir = manifest_dir.join("selfhost");
    let root_dir = manifest_dir
        .join("target")
        .join("integration-tests")
        .join("tl_emit_string_printed_programs");

    for (name, expr, exit_code, expected_stdout, snippets) in cases {
        let work_dir = root_dir.join(name);
        fs::create_dir_all(&work_dir).expect("create tl_emit string test work dir");

        for dep in ["emit_core.tl", "ast_types.tl", "sym_i64_env.tl"] {
            fs::copy(selfhost_dir.join(dep), work_dir.join(dep))
                .expect("copy imported emitter module to work dir");
        }

        let source = format!(
            "(import \"emit_core.tl\")\n\n\
             (define (sample) : Expr\n  {})\n\n\
             (define (main) : unit\n  (print-string (emit-program (sample))))\n",
            expr
        );
        let work_path = work_dir.join("driver.tl");
        fs::write(&work_path, source).expect("write tl_emit string driver");

        let output = Command::new(env!("CARGO_BIN_EXE_typelisp"))
            .arg("run")
            .arg(&work_path)
            .output()
            .expect("run tl_emit string driver");

        let stdout = String::from_utf8_lossy(&output.stdout);
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert_eq!(
            output.status.code(),
            Some(0),
            "{} driver exited unexpectedly\nstdout:\n{}\nstderr:\n{}",
            name,
            stdout,
            stderr,
        );
        for snippet in snippets {
            assert!(
                stdout.contains(snippet),
                "{} emitted assembly missing {:?}:\n{}",
                name,
                snippet,
                stdout,
            );
        }

        let asm_path = work_dir.join("printed.s");
        let obj_path = work_dir.join("printed.o");
        let bin_path = work_dir.join("printed");
        fs::write(&asm_path, &output.stdout).expect("write printed assembly");

        let status = Command::new("as")
            .arg(&asm_path)
            .arg("-o")
            .arg(&obj_path)
            .status()
            .expect("run assembler on printed tl_emit string output");
        assert!(status.success(), "{} assembly failed", name);

        let status = Command::new("ld")
            .arg(&obj_path)
            .arg("-o")
            .arg(&bin_path)
            .status()
            .expect("run linker on printed tl_emit string output");
        assert!(status.success(), "{} linking failed", name);

        let output = Command::new(&bin_path)
            .output()
            .expect("run binary assembled from printed tl_emit string output");
        let stdout = String::from_utf8_lossy(&output.stdout);
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert_eq!(
            output.status.code(),
            Some(exit_code),
            "{} printed program exited unexpectedly\nstdout:\n{}\nstderr:\n{}",
            name,
            stdout,
            stderr,
        );
        assert_eq!(
            stdout, expected_stdout,
            "{} printed program stdout differed\nstderr:\n{}",
            name, stderr,
        );
    }
}

#[test]
fn tl_emit_def_call_printed_programs_assemble_link_and_exit_expected() {
    let cases = [
        (
            "double_42",
            r#"(ILCons
  (IDefFn "double"
    (SLCons "x" SLNil)
    (EBin (OpMul) (EVar "x") (EInt 2)))
  ILNil)"#,
            r#"(ECall "double" (ELCons (EInt 21) ELNil))"#,
            42,
            &[
                "double:\n",
                "    sub $16, %rsp\n",
                "    movq %rdi, -8(%rbp)\n",
                "    popq %rdi\n",
                "    call double\n",
            ][..],
        ),
        (
            "add_42",
            r#"(ILCons
  (IDefFn "add"
    (SLCons "x" (SLCons "y" SLNil))
    (EBin (OpAdd) (EVar "x") (EVar "y")))
  ILNil)"#,
            r#"(ECall "add" (ELCons (EInt 40) (ELCons (EInt 2) ELNil)))"#,
            42,
            &[
                "add:\n",
                "    movq %rdi, -8(%rbp)\n",
                "    movq %rsi, -16(%rbp)\n",
                "    popq %rsi\n",
                "    popq %rdi\n",
                "    call add\n",
            ][..],
        ),
        (
            "fact_120",
            r#"(ILCons
  (IDefFn "fact"
    (SLCons "n" SLNil)
    (EIf
      (EBin (OpEq) (EVar "n") (EInt 0))
      (EInt 1)
      (EBin
        (OpMul)
        (EVar "n")
        (ECall "fact"
          (ELCons
            (EBin (OpSub) (EVar "n") (EInt 1))
            ELNil)))))
  ILNil)"#,
            r#"(ECall "fact" (ELCons (EInt 5) ELNil))"#,
            120,
            &[
                "fact:\n",
                "    sete %al\n",
                "    call fact\n",
                "    mov %rbp, %rsp\n",
            ][..],
        ),
        (
            "mutual_even_8",
            r#"(ILCons
  (IDefFn "even"
    (SLCons "n" SLNil)
    (EIf
      (EBin (OpEq) (EVar "n") (EInt 0))
      (EInt 1)
      (ECall "odd"
        (ELCons
          (EBin (OpSub) (EVar "n") (EInt 1))
          ELNil))))
  (ILCons
    (IDefFn "odd"
      (SLCons "n" SLNil)
      (EIf
        (EBin (OpEq) (EVar "n") (EInt 0))
        (EInt 0)
        (ECall "even"
          (ELCons
            (EBin (OpSub) (EVar "n") (EInt 1))
            ELNil))))
    ILNil))"#,
            r#"(ECall "even" (ELCons (EInt 8) ELNil))"#,
            1,
            &["even:\n", "odd:\n", "    call odd\n", "    call even\n"][..],
        ),
        (
            "call_with_let_arg_49",
            r#"(ILCons
  (IDefFn "sq"
    (SLCons "x" SLNil)
    (EBin (OpMul) (EVar "x") (EVar "x")))
  ILNil)"#,
            r#"(ELet "a" (EInt 7) (ECall "sq" (ELCons (EVar "a") ELNil)))"#,
            49,
            &[
                "sq:\n",
                "    movq %rax, -8(%rbp)\n",
                "    movq -8(%rbp), %rax\n",
                "    call sq\n",
            ][..],
        ),
    ];

    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let selfhost_dir = manifest_dir.join("selfhost");
    let root_dir = manifest_dir
        .join("target")
        .join("integration-tests")
        .join("tl_emit_def_call_printed_programs");

    for (name, defs, expr, exit_code, snippets) in cases {
        let work_dir = root_dir.join(name);
        fs::create_dir_all(&work_dir).expect("create tl_emit def/call test work dir");

        for dep in ["emit_core.tl", "ast_types.tl", "sym_i64_env.tl"] {
            fs::copy(selfhost_dir.join(dep), work_dir.join(dep))
                .expect("copy imported emitter module to work dir");
        }

        let source = format!(
            "(import \"emit_core.tl\")\n\n\
             (define (defs) : ItemList\n  {})\n\n\
             (define (sample) : Expr\n  {})\n\n\
             (define (main) : unit\n  (print-string (emit-program-with-defs (defs) (sample))))\n",
            defs, expr
        );
        let work_path = work_dir.join("driver.tl");
        fs::write(&work_path, source).expect("write tl_emit def/call driver");

        let output = Command::new(env!("CARGO_BIN_EXE_typelisp"))
            .arg("run")
            .arg(&work_path)
            .output()
            .expect("run tl_emit def/call driver");

        let stdout = String::from_utf8_lossy(&output.stdout);
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert_eq!(
            output.status.code(),
            Some(0),
            "{} driver exited unexpectedly\nstdout:\n{}\nstderr:\n{}",
            name,
            stdout,
            stderr,
        );
        for snippet in snippets {
            assert!(
                stdout.contains(snippet),
                "{} emitted assembly missing {:?}:\n{}",
                name,
                snippet,
                stdout,
            );
        }

        let asm_path = work_dir.join("printed.s");
        let obj_path = work_dir.join("printed.o");
        let bin_path = work_dir.join("printed");
        fs::write(&asm_path, &output.stdout).expect("write printed assembly");

        let status = Command::new("as")
            .arg(&asm_path)
            .arg("-o")
            .arg(&obj_path)
            .status()
            .expect("run assembler on printed tl_emit def/call output");
        assert!(status.success(), "{} assembly failed", name);

        let status = Command::new("ld")
            .arg(&obj_path)
            .arg("-o")
            .arg(&bin_path)
            .status()
            .expect("run linker on printed tl_emit def/call output");
        assert!(status.success(), "{} linking failed", name);

        let output = Command::new(&bin_path)
            .output()
            .expect("run binary assembled from printed tl_emit def/call output");
        let stdout = String::from_utf8_lossy(&output.stdout);
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert_eq!(
            output.status.code(),
            Some(exit_code),
            "{} printed program exited unexpectedly\nstdout:\n{}\nstderr:\n{}",
            name,
            stdout,
            stderr,
        );
        assert_eq!(stdout, "", "{} printed program wrote stdout", name);
    }
}

/// End-to-end self-hosted pipeline (#154/#163/#167): `selfhost/parse.tl` runs
/// `(emit-program (parse (read (lex "(let ((x 5)) (if (< x 10) 1 0))"))))`,
/// taking SOURCE TEXT all the way to a runnable `.s` in TypeLisp: lex -> read ->
/// parse -> emit. The demo now binds a let slot AND branches on a comparison, so
/// this test checks both the emitted let-slot path and the comparison/branch
/// path, then assembles + links + runs it and asserts exit 1 (x=5 <= 5 -> 1).
#[test]
fn tl_parse_printed_program_assembles_links_and_exits_1() {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let selfhost_dir = manifest_dir.join("selfhost");
    let source_path = selfhost_dir.join("parse.tl");
    let work_dir = manifest_dir
        .join("target")
        .join("integration-tests")
        .join("tl_parse_printed_program");
    fs::create_dir_all(&work_dir).expect("create tl_parse printed-program test work dir");

    let work_path = work_dir.join("parse.tl");
    fs::copy(&source_path, &work_path).expect("copy parse.tl to work dir");

    // Copy imported modules alongside so the `(import)` chain resolves at load time.
    for dep in [
        "parse_core.tl",
        "emit_core.tl",
        "sym_i64_env.tl",
        "ast_types.tl",
        "read.tl",
        "lex.tl",
        "token.tl",
    ] {
        fs::copy(selfhost_dir.join(dep), work_dir.join(dep))
            .expect("copy imported front-end module to work dir");
    }

    let output = Command::new(env!("CARGO_BIN_EXE_typelisp"))
        .arg("run")
        .arg(&work_path)
        .output()
        .expect("run tl_parse");

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert_eq!(
        output.status.code(),
        Some(0),
        "tl_parse driver exited unexpectedly\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr,
    );
    for snippet in [
        "    sub $16, %rsp\n",
        "    movq %rax, -8(%rbp)\n",
        "    movq -8(%rbp), %rax\n",
        "    add $16, %rsp\n",
        // refs #167/#173: the comparison `(<= x 5)` and the `if` branch.
        "    setle %al\n",
        "    cmpq $0, %rax\n",
        "    je .Lelse_",
        "    jmp .Lend_",
        ".Lelse_",
        ".Lend_",
    ] {
        assert!(
            stdout.contains(snippet),
            "tl_parse printed program missing {:?}\nstderr:\n{}\nstdout:\n{}",
            snippet,
            stderr,
            stdout,
        );
    }
    assert!(
        !stdout.contains("    .section .rodata\n"),
        "no-string tl_parse demo should not emit rodata:\n{}",
        stdout,
    );

    let asm_path = work_dir.join("printed.s");
    let obj_path = work_dir.join("printed.o");
    let bin_path = work_dir.join("printed");
    fs::write(&asm_path, &output.stdout).expect("write printed assembly");

    let status = Command::new("as")
        .arg(&asm_path)
        .arg("-o")
        .arg(&obj_path)
        .status()
        .expect("run assembler on printed tl_parse output");
    assert!(
        status.success(),
        "assembling printed tl_parse output failed"
    );

    let status = Command::new("ld")
        .arg(&obj_path)
        .arg("-o")
        .arg(&bin_path)
        .status()
        .expect("run linker on printed tl_parse output");
    assert!(status.success(), "linking printed tl_parse output failed");

    let output = Command::new(&bin_path)
        .output()
        .expect("run binary assembled from printed tl_parse output");
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert_eq!(
        output.status.code(),
        Some(1),
        "printed tl_parse program exited unexpectedly\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr,
    );
    assert_eq!(stdout, "", "printed tl_parse program wrote stdout");
}

/// File-to-file bootstrap smoke (#226): a TypeLisp program reads source text
/// and an output path from argv, runs the current selfhost
/// lex -> read-form -> parse-program -> emit-program-with-defs pipeline, writes
/// `.s`, and the Rust harness handles the external assemble/link step.
#[test]
fn tl_compile_smoke_writes_assembly_file_and_output_exits_1() {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let selfhost_dir = manifest_dir.join("selfhost");
    let source_path = selfhost_dir.join("compile_smoke.tl");
    let work_dir = manifest_dir
        .join("target")
        .join("integration-tests")
        .join("tl_compile_smoke");
    fs::create_dir_all(&work_dir).expect("create tl_compile_smoke test work dir");

    let work_path = work_dir.join("compile_smoke.tl");
    fs::copy(&source_path, &work_path).expect("copy compile_smoke.tl to work dir");

    for dep in [
        "parse_core.tl",
        "emit_core.tl",
        "sym_i64_env.tl",
        "ast_types.tl",
        "read.tl",
        "lex.tl",
        "token.tl",
    ] {
        fs::copy(selfhost_dir.join(dep), work_dir.join(dep))
            .expect("copy imported selfhost module to work dir");
    }

    let input_path = work_dir.join("input.tl");
    let asm_path = work_dir.join("generated.s");
    let obj_path = work_dir.join("generated.o");
    let bin_path = work_dir.join("generated");
    fs::write(&input_path, "(let ((x 5)) (if (<= x 5) 1 0))")
        .expect("write tl_compile_smoke input");

    let output = Command::new(env!("CARGO_BIN_EXE_typelisp"))
        .arg("run")
        .arg(&work_path)
        .arg(&input_path)
        .arg(&asm_path)
        .output()
        .expect("run tl_compile_smoke");

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert_eq!(
        output.status.code(),
        Some(0),
        "tl_compile_smoke driver exited unexpectedly\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr,
    );
    assert_eq!(stdout, "", "tl_compile_smoke driver wrote stdout");
    assert_eq!(stderr, "", "tl_compile_smoke driver wrote stderr");

    let asm = fs::read_to_string(&asm_path).expect("read tl_compile_smoke output");
    for snippet in [
        "main:\n",
        "_start:\n",
        "    call main\n",
        "    setle %al\n",
        "    cmpq $0, %rax\n",
        "    je .Lelse_",
        "    jmp .Lend_",
    ] {
        assert!(
            asm.contains(snippet),
            "tl_compile_smoke output assembly missing {:?}:\n{}",
            snippet,
            asm,
        );
    }

    let status = Command::new("as")
        .arg(&asm_path)
        .arg("-o")
        .arg(&obj_path)
        .status()
        .expect("run assembler on tl_compile_smoke output");
    assert!(
        status.success(),
        "assembling tl_compile_smoke output failed"
    );

    let status = Command::new("ld")
        .arg(&obj_path)
        .arg("-o")
        .arg(&bin_path)
        .status()
        .expect("run linker on tl_compile_smoke output");
    assert!(status.success(), "linking tl_compile_smoke output failed");

    let output = Command::new(&bin_path)
        .output()
        .expect("run binary assembled from tl_compile_smoke output");
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert_eq!(
        output.status.code(),
        Some(1),
        "tl_compile_smoke output program exited unexpectedly\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr,
    );
    assert_eq!(stdout, "", "tl_compile_smoke output program wrote stdout");
}

#[test]
fn tl_compile_smoke_writes_definition_program_and_output_exits_42() {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let selfhost_dir = manifest_dir.join("selfhost");
    let source_path = selfhost_dir.join("compile_smoke.tl");
    let work_dir = manifest_dir
        .join("target")
        .join("integration-tests")
        .join("tl_compile_smoke_defs");
    fs::create_dir_all(&work_dir).expect("create tl_compile_smoke defs test work dir");

    let work_path = work_dir.join("compile_smoke.tl");
    fs::copy(&source_path, &work_path).expect("copy compile_smoke.tl to work dir");

    for dep in [
        "parse_core.tl",
        "emit_core.tl",
        "sym_i64_env.tl",
        "ast_types.tl",
        "read.tl",
        "lex.tl",
        "token.tl",
    ] {
        fs::copy(selfhost_dir.join(dep), work_dir.join(dep))
            .expect("copy imported selfhost module to work dir");
    }

    let input_path = work_dir.join("input_defs.tl");
    let asm_path = work_dir.join("generated_defs.s");
    let obj_path = work_dir.join("generated_defs.o");
    let bin_path = work_dir.join("generated_defs");
    fs::write(&input_path, "(define (double x) (+ x x))\n(double 21)")
        .expect("write tl_compile_smoke defs input");

    let output = Command::new(env!("CARGO_BIN_EXE_typelisp"))
        .arg("run")
        .arg(&work_path)
        .arg(&input_path)
        .arg(&asm_path)
        .output()
        .expect("run tl_compile_smoke defs");

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert_eq!(
        output.status.code(),
        Some(0),
        "tl_compile_smoke defs driver exited unexpectedly\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr,
    );
    assert_eq!(stdout, "", "tl_compile_smoke defs driver wrote stdout");
    assert_eq!(stderr, "", "tl_compile_smoke defs driver wrote stderr");

    let asm = fs::read_to_string(&asm_path).expect("read tl_compile_smoke defs output");
    for snippet in [
        "double:\n",
        "main:\n",
        "_start:\n",
        "    call double\n",
        "    addq %rcx, %rax\n",
    ] {
        assert!(
            asm.contains(snippet),
            "tl_compile_smoke defs output assembly missing {:?}:\n{}",
            snippet,
            asm,
        );
    }

    let status = Command::new("as")
        .arg(&asm_path)
        .arg("-o")
        .arg(&obj_path)
        .status()
        .expect("run assembler on tl_compile_smoke defs output");
    assert!(
        status.success(),
        "assembling tl_compile_smoke defs output failed"
    );

    let status = Command::new("ld")
        .arg(&obj_path)
        .arg("-o")
        .arg(&bin_path)
        .status()
        .expect("run linker on tl_compile_smoke defs output");
    assert!(
        status.success(),
        "linking tl_compile_smoke defs output failed"
    );

    let output = Command::new(&bin_path)
        .output()
        .expect("run binary assembled from tl_compile_smoke defs output");
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert_eq!(
        output.status.code(),
        Some(42),
        "tl_compile_smoke defs output program exited unexpectedly\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr,
    );
    assert_eq!(
        stdout, "",
        "tl_compile_smoke defs output program wrote stdout"
    );
}

fn run_compile_smoke_generated_program(
    work_name: &str,
    input_source: &str,
    asm_snippets: &[&str],
) -> (Option<i32>, String, String, String) {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let selfhost_dir = manifest_dir.join("selfhost");
    let source_path = selfhost_dir.join("compile_smoke.tl");
    let work_dir = manifest_dir
        .join("target")
        .join("integration-tests")
        .join(work_name);
    fs::create_dir_all(&work_dir).expect("create tl_compile_smoke begin test work dir");

    let work_path = work_dir.join("compile_smoke.tl");
    fs::copy(&source_path, &work_path).expect("copy compile_smoke.tl to work dir");

    for dep in [
        "parse_core.tl",
        "emit_core.tl",
        "sym_i64_env.tl",
        "ast_types.tl",
        "read.tl",
        "lex.tl",
        "token.tl",
    ] {
        fs::copy(selfhost_dir.join(dep), work_dir.join(dep))
            .unwrap_or_else(|err| panic!("copy imported selfhost module {dep} to work dir: {err}"));
    }

    let input_path = work_dir.join("input.tl");
    let asm_path = work_dir.join("generated.s");
    let obj_path = work_dir.join("generated.o");
    let bin_path = work_dir.join("generated");
    fs::write(&input_path, input_source).expect("write tl_compile_smoke input");

    let output = Command::new(env!("CARGO_BIN_EXE_typelisp"))
        .arg("run")
        .arg(&work_path)
        .arg(&input_path)
        .arg(&asm_path)
        .output()
        .expect("run tl_compile_smoke");

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert_eq!(
        output.status.code(),
        Some(0),
        "tl_compile_smoke driver exited unexpectedly\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr,
    );
    assert_eq!(stdout, "", "tl_compile_smoke driver wrote stdout");
    assert_eq!(stderr, "", "tl_compile_smoke driver wrote stderr");

    let asm = fs::read_to_string(&asm_path).expect("read tl_compile_smoke output");
    for snippet in asm_snippets {
        assert!(
            asm.contains(snippet),
            "tl_compile_smoke output assembly missing {:?}:\n{}",
            snippet,
            asm,
        );
    }

    let status = Command::new("as")
        .arg(&asm_path)
        .arg("-o")
        .arg(&obj_path)
        .status()
        .expect("run assembler on tl_compile_smoke output");
    assert!(
        status.success(),
        "assembling tl_compile_smoke output failed"
    );

    let status = Command::new("ld")
        .arg(&obj_path)
        .arg("-o")
        .arg(&bin_path)
        .status()
        .expect("run linker on tl_compile_smoke output");
    assert!(status.success(), "linking tl_compile_smoke output failed");

    let output = Command::new(&bin_path)
        .output()
        .expect("run binary assembled from tl_compile_smoke output");
    let stdout = String::from_utf8_lossy(&output.stdout).to_string();
    let stderr = String::from_utf8_lossy(&output.stderr).to_string();

    (output.status.code(), stdout, stderr, asm)
}

#[test]
fn tl_compile_smoke_writes_begin_program_and_output_prints_hi_exits_7() {
    let (code, stdout, stderr, _asm) = run_compile_smoke_generated_program(
        "tl_compile_smoke_begin",
        "(begin (print \"hi\") 7)",
        &[
            ".Lstr_0:\n    .string \"hi\"",
            "    syscall\n    movq $0, %rax\n    movq $7, %rax\n",
        ],
    );

    assert_eq!(
        code,
        Some(7),
        "tl_compile_smoke begin output program exited unexpectedly\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr,
    );
    assert_eq!(stdout, "hi", "tl_compile_smoke begin output stdout");
    assert_eq!(stderr, "", "tl_compile_smoke begin output stderr");
}

#[test]
fn tl_compile_smoke_writes_begin_function_body_and_output_exits_42() {
    let (code, stdout, stderr, _asm) = run_compile_smoke_generated_program(
        "tl_compile_smoke_begin_defs",
        "(define (answer) (begin 1 42))\n(answer)",
        &[
            "answer:\n",
            "    movq $1, %rax\n    movq $42, %rax\n",
            "    call answer\n",
        ],
    );

    assert_eq!(
        code,
        Some(42),
        "tl_compile_smoke begin defs output program exited unexpectedly\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr,
    );
    assert_eq!(stdout, "", "tl_compile_smoke begin defs output stdout");
    assert_eq!(stderr, "", "tl_compile_smoke begin defs output stderr");
}

#[test]
fn tl_compile_smoke_writes_local_set_program_and_output_exits_42() {
    let (code, stdout, stderr, _asm) = run_compile_smoke_generated_program(
        "tl_compile_smoke_set_local",
        "(let ((x 1)) (begin (set! x 41) (+ x 1)))",
        &[
            "    movq $41, %rax\n    movq %rax, -8(%rbp)\n    movq $0, %rax\n",
            "    movq -8(%rbp), %rax\n",
        ],
    );

    assert_eq!(
        code,
        Some(42),
        "tl_compile_smoke set local output program exited unexpectedly\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr,
    );
    assert_eq!(stdout, "", "tl_compile_smoke set local output stdout");
    assert_eq!(stderr, "", "tl_compile_smoke set local output stderr");
}

#[test]
fn tl_compile_smoke_writes_function_set_body_and_output_exits_42() {
    let (code, stdout, stderr, _asm) = run_compile_smoke_generated_program(
        "tl_compile_smoke_set_defs",
        "(define (bump x) (begin (set! x (+ x 1)) x))\n(bump 41)",
        &[
            "bump:\n",
            "    addq %rcx, %rax\n    movq %rax, -8(%rbp)\n    movq $0, %rax\n",
            "    call bump\n",
        ],
    );

    assert_eq!(
        code,
        Some(42),
        "tl_compile_smoke set defs output program exited unexpectedly\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr,
    );
    assert_eq!(stdout, "", "tl_compile_smoke set defs output stdout");
    assert_eq!(stderr, "", "tl_compile_smoke set defs output stderr");
}

#[test]
fn tl_compile_smoke_writes_while_program_and_output_exits_42() {
    let (code, stdout, stderr, _asm) = run_compile_smoke_generated_program(
        "tl_compile_smoke_while",
        "(let ((i 0)) (let ((acc 0)) (begin (while (< i 6) (begin (set! acc (+ acc 7)) (set! i (+ i 1)))) acc)))",
        &[
            ".Lwhile_",
            ".Lwend_",
            "    jmp .Lwhile_",
            "    movq $0, %rax\n    movq -16(%rbp), %rax\n",
        ],
    );

    assert_eq!(
        code,
        Some(42),
        "tl_compile_smoke while output program exited unexpectedly\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr,
    );
    assert_eq!(stdout, "", "tl_compile_smoke while output stdout");
    assert_eq!(stderr, "", "tl_compile_smoke while output stderr");
}

#[test]
fn tl_compile_smoke_writes_multi_binding_let_and_output_exits_42() {
    // Sequential let* semantics: later bindings can reference earlier ones.
    let (code, stdout, stderr, _asm) = run_compile_smoke_generated_program(
        "tl_compile_smoke_multi_let",
        "(let ((x 20) (y (+ x 22))) y)",
        &[
            "_start:\n",
            "    call main\n",
            "    movq $60, %rax\n",
            "    syscall\n",
        ],
    );

    assert_eq!(
        code,
        Some(42),
        "tl_compile_smoke multi-binding let output program exited unexpectedly\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr,
    );
    assert_eq!(
        stdout, "",
        "tl_compile_smoke multi-binding let output stdout"
    );
    assert_eq!(
        stderr, "",
        "tl_compile_smoke multi-binding let output stderr"
    );
}

#[test]
fn tl_compile_smoke_writes_boolean_program_and_output_exits_42() {
    let (code, stdout, stderr, _asm) = run_compile_smoke_generated_program(
        "tl_compile_smoke_boolean_ops",
        "(let ((x 0)) (begin (while (and (< x 6) (not (= x 6))) (set! x (+ x 1))) (if (and (or (= x 6) 0) (not (and 2 0))) 42 1)))",
        &[
            "    andq %rcx, %rax\n",
            "    orq %rcx, %rax\n",
            "    cmpq $0, %rax\n    sete %al\n    movzbq %al, %rax\n",
            "    cmpq $0, %rcx\n    setne %cl\n    movzbq %cl, %rcx\n",
        ],
    );

    assert_eq!(
        code,
        Some(42),
        "tl_compile_smoke boolean output program exited unexpectedly\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr,
    );
    assert_eq!(stdout, "", "tl_compile_smoke boolean output stdout");
    assert_eq!(stderr, "", "tl_compile_smoke boolean output stderr");
}

fn run_compile_smoke_driver(work_name: &str, input_source: &str) -> (Option<i32>, String, String) {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let selfhost_dir = manifest_dir.join("selfhost");
    let source_path = selfhost_dir.join("compile_smoke.tl");
    let work_dir = manifest_dir
        .join("target")
        .join("integration-tests")
        .join(work_name);
    fs::create_dir_all(&work_dir).expect("create tl_compile_smoke test work dir");

    let work_path = work_dir.join("compile_smoke.tl");
    fs::copy(&source_path, &work_path).expect("copy compile_smoke.tl to work dir");

    for dep in [
        "parse_core.tl",
        "emit_core.tl",
        "sym_i64_env.tl",
        "ast_types.tl",
        "read.tl",
        "lex.tl",
        "token.tl",
    ] {
        fs::copy(selfhost_dir.join(dep), work_dir.join(dep))
            .unwrap_or_else(|err| panic!("copy imported selfhost module {dep} to work dir: {err}"));
    }

    let input_path = work_dir.join("input.tl");
    let asm_path = work_dir.join("generated.s");
    fs::write(&input_path, input_source).expect("write tl_compile_smoke input");

    let output = Command::new(env!("CARGO_BIN_EXE_typelisp"))
        .arg("run")
        .arg(&work_path)
        .arg(&input_path)
        .arg(&asm_path)
        .output()
        .expect("run tl_compile_smoke");
    let stdout = String::from_utf8_lossy(&output.stdout).to_string();
    let stderr = String::from_utf8_lossy(&output.stderr).to_string();

    (output.status.code(), stdout, stderr)
}

#[test]
fn tl_compile_smoke_rejects_malformed_while_with_specific_diagnostic() {
    let (code, stdout, stderr) =
        run_compile_smoke_driver("tl_compile_smoke_malformed_while", "(while)");

    assert_eq!(
        code,
        Some(1),
        "malformed while should return a recoverable parse error\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr,
    );
    assert_eq!(stdout, "", "malformed while driver wrote stdout");
    assert_eq!(
        stderr, "parse: malformed while",
        "malformed while diagnostic"
    );
}

#[test]
fn tl_compile_smoke_rejects_empty_begin_with_specific_diagnostic() {
    let (code, stdout, stderr) =
        run_compile_smoke_driver("tl_compile_smoke_empty_begin", "(begin)");

    assert_eq!(
        code,
        Some(1),
        "empty begin should return a recoverable parse error\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr,
    );
    assert_eq!(stdout, "", "empty begin driver wrote stdout");
    assert_eq!(stderr, "parse: empty begin", "empty begin diagnostic");
}

#[test]
fn tl_compile_smoke_rejects_malformed_if_without_panic_abort() {
    let (code, stdout, stderr) =
        run_compile_smoke_driver("tl_compile_smoke_malformed_if", "(if 1 2)");

    assert_eq!(
        code,
        Some(1),
        "malformed if should return a recoverable parse error\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr,
    );
    assert_eq!(stdout, "", "malformed if driver wrote stdout");
    assert_eq!(stderr, "parse: malformed if", "malformed if diagnostic");
}

#[test]
fn tl_compile_smoke_rejects_malformed_boolean_ops_with_specific_diagnostics() {
    for (work_name, input, expected) in [
        (
            "tl_compile_smoke_malformed_and",
            "(and 1)",
            "parse: malformed and",
        ),
        (
            "tl_compile_smoke_malformed_or",
            "(or 1 2 3)",
            "parse: malformed or",
        ),
        (
            "tl_compile_smoke_malformed_not",
            "(not 1 2)",
            "parse: malformed not",
        ),
    ] {
        let (code, stdout, stderr) = run_compile_smoke_driver(work_name, input);

        assert_eq!(
            code,
            Some(1),
            "{work_name} should return a recoverable parse error\nstdout:\n{stdout}\nstderr:\n{stderr}",
        );
        assert_eq!(stdout, "", "{work_name} driver wrote stdout");
        assert_eq!(stderr, expected, "{work_name} diagnostic");
    }
}

fn tl_string_literal(text: &str) -> String {
    text.replace('\\', "\\\\").replace('"', "\\\"")
}

#[test]
fn argv_builtins_receive_run_args() {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let source_path = manifest_dir
        .join("tests")
        .join("integration")
        .join("argv.tl");
    let work_dir = manifest_dir
        .join("target")
        .join("integration-tests")
        .join("argv");
    fs::create_dir_all(&work_dir).expect("create argv test work dir");
    let work_path = work_dir.join("argv.tl");
    fs::copy(&source_path, &work_path).expect("copy argv.tl to work dir");

    let output = Command::new(env!("CARGO_BIN_EXE_typelisp"))
        .arg("run")
        .arg(&work_path)
        .arg("alpha")
        .arg("beta")
        .output()
        .expect("run typelisp argv fixture");

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert_eq!(
        output.status.code(),
        Some(7),
        "argv fixture exited unexpectedly\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr,
    );
    assert_eq!(stdout, "alpha\n", "argv fixture stdout differed");
}

#[test]
fn argv_out_of_bounds_aborts() {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let work_dir = manifest_dir
        .join("target")
        .join("integration-tests")
        .join("argv_out_of_bounds");
    fs::create_dir_all(&work_dir).expect("create argv oob test work dir");
    let work_path = work_dir.join("argv_out_of_bounds.tl");
    fs::write(
        &work_path,
        r#"(define (main) : i64 (string-length (arg 99)))"#,
    )
    .expect("write argv oob fixture");

    let output = Command::new(env!("CARGO_BIN_EXE_typelisp"))
        .arg("run")
        .arg(&work_path)
        .output()
        .expect("run typelisp argv oob fixture");

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert_eq!(
        output.status.code(),
        Some(134),
        "argv oob fixture exited unexpectedly\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr,
    );
    assert_eq!(stdout, "", "argv oob fixture wrote stdout");
    assert!(
        stderr.contains("tl: argv index out of bounds"),
        "argv oob stderr differed:\n{}",
        stderr
    );
}

#[test]
fn read_file_builtin_reads_fixture_contents() {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let work_dir = manifest_dir
        .join("target")
        .join("integration-tests")
        .join("read-file");
    fs::create_dir_all(&work_dir).expect("create read-file test work dir");
    let fixture_path = work_dir.join("input.txt");
    fs::write(&fixture_path, "alpha\nbeta\n").expect("write read-file fixture");

    let fixture_literal = tl_string_literal(&fixture_path.to_string_lossy());
    let source = format!(
        r#"(define (main) : i64
  (let ([s : String (read-file "{}")])
    (begin
      (print-string s)
      (if (string-eq s "alpha\nbeta\n") 7 1))))"#,
        fixture_literal
    );
    let work_path = work_dir.join("read_file.tl");
    fs::write(&work_path, source).expect("write read-file TypeLisp fixture");

    let output = Command::new(env!("CARGO_BIN_EXE_typelisp"))
        .arg("run")
        .arg(&work_path)
        .output()
        .expect("run typelisp read-file fixture");

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert_eq!(
        output.status.code(),
        Some(7),
        "read-file fixture exited unexpectedly\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr,
    );
    assert_eq!(stdout, "alpha\nbeta\n", "read-file stdout differed");
}

#[test]
fn read_file_missing_path_aborts() {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let work_dir = manifest_dir
        .join("target")
        .join("integration-tests")
        .join("read-file-missing");
    fs::create_dir_all(&work_dir).expect("create missing read-file test work dir");
    let missing_path = work_dir.join("missing.txt");
    let missing_literal = tl_string_literal(&missing_path.to_string_lossy());
    let source = format!(
        r#"(define (main) : i64 (string-length (read-file "{}")))"#,
        missing_literal
    );
    let work_path = work_dir.join("read_file_missing.tl");
    fs::write(&work_path, source).expect("write missing read-file TypeLisp fixture");

    let output = Command::new(env!("CARGO_BIN_EXE_typelisp"))
        .arg("run")
        .arg(&work_path)
        .output()
        .expect("run typelisp missing read-file fixture");

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert_eq!(
        output.status.code(),
        Some(134),
        "missing read-file fixture exited unexpectedly\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr,
    );
    assert_eq!(stdout, "", "missing read-file fixture wrote stdout");
    assert!(
        stderr.contains("tl: read-file failed"),
        "missing read-file stderr differed:\n{}",
        stderr
    );
}

#[test]
fn write_file_builtin_writes_fixture_contents() {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let work_dir = manifest_dir
        .join("target")
        .join("integration-tests")
        .join("write-file");
    fs::create_dir_all(&work_dir).expect("create write-file test work dir");
    let output_path = work_dir.join("output.txt");
    let output_literal = tl_string_literal(&output_path.to_string_lossy());
    let source = format!(
        r#"(define (main) : unit
  (write-file "{}" "alpha\nbeta\n"))"#,
        output_literal
    );
    let work_path = work_dir.join("write_file.tl");
    fs::write(&work_path, source).expect("write write-file TypeLisp fixture");

    let output = Command::new(env!("CARGO_BIN_EXE_typelisp"))
        .arg("run")
        .arg(&work_path)
        .output()
        .expect("run typelisp write-file fixture");

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert_eq!(
        output.status.code(),
        Some(0),
        "write-file fixture exited unexpectedly\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr,
    );
    assert_eq!(stdout, "", "write-file fixture wrote stdout");
    assert_eq!(stderr, "", "write-file fixture wrote stderr");
    let contents = fs::read_to_string(&output_path).expect("read write-file output");
    assert_eq!(contents, "alpha\nbeta\n", "write-file contents differed");
}

#[test]
fn write_file_invalid_path_aborts() {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let work_dir = manifest_dir
        .join("target")
        .join("integration-tests")
        .join("write-file-invalid");
    fs::create_dir_all(&work_dir).expect("create invalid write-file test work dir");
    let output_path = work_dir.join("missing-parent").join("output.txt");
    let output_literal = tl_string_literal(&output_path.to_string_lossy());
    let source = format!(
        r#"(define (main) : unit
  (write-file "{}" "alpha"))"#,
        output_literal
    );
    let work_path = work_dir.join("write_file_invalid.tl");
    fs::write(&work_path, source).expect("write invalid write-file TypeLisp fixture");

    let output = Command::new(env!("CARGO_BIN_EXE_typelisp"))
        .arg("run")
        .arg(&work_path)
        .output()
        .expect("run typelisp invalid write-file fixture");

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert_eq!(
        output.status.code(),
        Some(134),
        "invalid write-file fixture exited unexpectedly\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr,
    );
    assert_eq!(stdout, "", "invalid write-file fixture wrote stdout");
    assert!(
        stderr.contains("tl: write-file failed"),
        "invalid write-file stderr differed:\n{}",
        stderr
    );
}

#[test]
fn selfhost_doc_driver_writes_single_file_markdown() {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let selfhost_dir = manifest_dir.join("selfhost");
    let work_dir = manifest_dir
        .join("target")
        .join("integration-tests")
        .join("selfhost-doc-driver");
    fs::create_dir_all(&work_dir).expect("create selfhost doc driver test work dir");

    let driver_path = work_dir.join("doc.tl");
    fs::copy(selfhost_dir.join("doc.tl"), &driver_path).expect("copy doc.tl to work dir");
    copy_case_deps(
        &manifest_dir,
        &selfhost_dir,
        &work_dir,
        &["doc_render.tl", "doc_extract.tl", "format_tokens.tl"],
    );

    let input_path = work_dir.join("fixture.tl");
    fs::write(
        &input_path,
        concat!(
            ";;;; Module docs for driver output.\n",
            ";;;; Includes a second line.\n",
            "\n",
            ";; ordinary comment ignored\n",
            ";;; Public answer docs.\n",
            "(define answer : i64 42)\n",
            "\n",
            "(define undocumented : i64 7)\n",
            "\n",
            ";;; Function docs.\n",
            "(define (add-one [x : i64]) : i64 (+ x 1))\n",
        ),
    )
    .expect("write doc driver input fixture");
    let output_path = work_dir.join("fixture.md");

    let output = Command::new(env!("CARGO_BIN_EXE_typelisp"))
        .arg("run")
        .arg(&driver_path)
        .arg("--")
        .arg(&input_path)
        .arg(&output_path)
        .output()
        .expect("run selfhost doc driver");

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert_eq!(
        output.status.code(),
        Some(0),
        "doc driver exited unexpectedly\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr,
    );
    assert_eq!(stdout, "", "doc driver wrote stdout");
    assert_eq!(stderr, "", "doc driver wrote stderr");

    let rendered = fs::read_to_string(&output_path).expect("read generated markdown");
    let expected = concat!(
        "# TypeLisp Documentation\n",
        "\n",
        "Module docs for driver output.\n",
        "Includes a second line.\n",
        "\n",
        "## Items\n",
        "\n",
        "<a id=\"tl-answer\"></a>\n",
        "\n",
        "### answer\n",
        "\n",
        "Kind: define\n",
        "\n",
        "```typelisp\n",
        "(define answer : i64 42)\n",
        "```\n",
        "\n",
        "Public answer docs.\n",
        "\n",
        "<a id=\"tl-add-one\"></a>\n",
        "\n",
        "### add-one\n",
        "\n",
        "Kind: define-function\n",
        "\n",
        "```typelisp\n",
        "(define (add-one [x : i64]) : i64 (+ x 1))\n",
        "```\n",
        "\n",
        "Function docs.\n",
        "\n",
    );
    assert_eq!(rendered, expected, "doc driver markdown differed");
    assert!(
        !rendered.contains("undocumented"),
        "undocumented declarations should not be rendered yet:\n{}",
        rendered
    );

    let invalid = Command::new(env!("CARGO_BIN_EXE_typelisp"))
        .arg("run")
        .arg(&driver_path)
        .arg("--")
        .output()
        .expect("run selfhost doc driver without paths");

    let invalid_stdout = String::from_utf8_lossy(&invalid.stdout);
    let invalid_stderr = String::from_utf8_lossy(&invalid.stderr);
    assert_eq!(
        invalid.status.code(),
        Some(1),
        "doc driver invalid-args run exited unexpectedly\nstdout:\n{}\nstderr:\n{}",
        invalid_stdout,
        invalid_stderr,
    );
    assert_eq!(
        invalid_stdout, "",
        "doc driver invalid-args run wrote stdout"
    );
    assert!(
        invalid_stderr.contains("doc: expected input and output paths"),
        "doc driver invalid-args stderr differed:\n{}",
        invalid_stderr
    );
}

#[test]
fn selfhost_eval_reports_recoverable_errors() {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let selfhost_dir = manifest_dir.join("selfhost");
    let work_dir = manifest_dir
        .join("target")
        .join("integration-tests")
        .join("selfhost-eval-errors");
    fs::create_dir_all(&work_dir).expect("create selfhost eval error test work dir");

    let driver_path = work_dir.join("eval.tl");
    fs::copy(selfhost_dir.join("eval.tl"), &driver_path).expect("copy eval.tl to work dir");
    copy_case_deps(
        &manifest_dir,
        &selfhost_dir,
        &work_dir,
        &["read.tl", "lex.tl", "token.tl"],
    );

    for (name, source, expected_stderr) in [
        ("type_mismatch", r#"(+ "a" 1)"#, "type error: expected int"),
        ("unbound_variable", "missing", "eval: unbound variable"),
        (
            "arity_mismatch",
            "(define (id x) x) (id)",
            "eval: too few arguments in call",
        ),
    ] {
        let output = Command::new(env!("CARGO_BIN_EXE_typelisp"))
            .arg("run")
            .arg(&driver_path)
            .arg("--")
            .arg(source)
            .output()
            .unwrap_or_else(|err| panic!("run selfhost eval error case {name}: {err}"));

        let stdout = String::from_utf8_lossy(&output.stdout);
        let stderr = String::from_utf8_lossy(&output.stderr);
        assert_eq!(
            output.status.code(),
            Some(1),
            "selfhost eval error case {name} exited unexpectedly\nstdout:\n{}\nstderr:\n{}",
            stdout,
            stderr,
        );
        assert_eq!(stdout, "", "selfhost eval error case {name} wrote stdout");
        assert!(
            stderr.contains(expected_stderr),
            "selfhost eval error case {name} stderr differed\nexpected substring: {expected_stderr}\nstderr:\n{stderr}",
        );
    }
}

#[test]
fn file_exists_builtin_reports_existing_and_missing_paths() {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let work_dir = manifest_dir
        .join("target")
        .join("integration-tests")
        .join("file-exists");
    fs::create_dir_all(&work_dir).expect("create file-exists test work dir");
    let existing_path = work_dir.join("input.txt");
    let missing_path = work_dir.join("missing.txt");
    fs::write(&existing_path, "alpha\n").expect("write file-exists fixture");

    let existing_literal = tl_string_literal(&existing_path.to_string_lossy());
    let missing_literal = tl_string_literal(&missing_path.to_string_lossy());
    let source = format!(
        r#"(define (main) : i64
  (let ([existing : bool (file-exists? "{}")]
        [missing : bool (file-exists? "{}")])
    (if existing
        (if missing 1 7)
        2)))"#,
        existing_literal, missing_literal
    );
    let work_path = work_dir.join("file_exists.tl");
    fs::write(&work_path, source).expect("write file-exists TypeLisp fixture");

    let output = Command::new(env!("CARGO_BIN_EXE_typelisp"))
        .arg("run")
        .arg(&work_path)
        .output()
        .expect("run typelisp file-exists fixture");

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert_eq!(
        output.status.code(),
        Some(7),
        "file-exists fixture exited unexpectedly\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr,
    );
    assert_eq!(stdout, "", "file-exists fixture wrote stdout");
    assert_eq!(stderr, "", "file-exists fixture wrote stderr");
}

#[test]
fn user_defined_file_exists_predicate_name_assembles() {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let work_dir = manifest_dir
        .join("target")
        .join("integration-tests")
        .join("file-exists-shadow");
    fs::create_dir_all(&work_dir).expect("create file-exists shadow test work dir");
    let work_path = work_dir.join("file_exists_shadow.tl");
    fs::write(
        &work_path,
        r#"
(define (file-exists? [n : i64]) : i64 (+ n 1))
(define (main) : i64 (file-exists? 41))
"#,
    )
    .expect("write file-exists shadow TypeLisp fixture");

    let output = Command::new(env!("CARGO_BIN_EXE_typelisp"))
        .arg("run")
        .arg(&work_path)
        .output()
        .expect("run typelisp file-exists shadow fixture");

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert_eq!(
        output.status.code(),
        Some(42),
        "file-exists shadow fixture exited unexpectedly\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr,
    );
}

fn source_path_for_case(manifest_dir: &PathBuf, name: &str) -> PathBuf {
    let integration_path = manifest_dir
        .join("tests")
        .join("integration")
        .join(format!("{name}.tl"));
    if integration_path.exists() {
        return integration_path;
    }

    let selfhost_file = match name {
        "tl_ast" => "ast.tl",
        "tl_emit" => "emit.tl",
        "tl_eval" => "eval.tl",
        "tl_lex" => "lex.tl",
        "tl_lexer" => "lexer.tl",
        "tl_parse" => "parse.tl",
        "compiler_parse_smoke" => "compiler_parse_smoke.tl",
        "compiler_symbols_smoke" => "compiler_symbols_smoke.tl",
        "compiler_typecheck_smoke" => "compiler_typecheck_smoke.tl",
        "compiler_lower_smoke" => "compiler_lower_smoke.tl",
        "compiler_liveness_smoke" => "compiler_liveness_smoke.tl",
        "compiler_optimize_smoke" => "compiler_optimize_smoke.tl",
        "compiler_backend_smoke" => "compiler_backend_smoke.tl",
        "doc_extract_smoke" => "doc_extract_smoke.tl",
        "doc_render_smoke" => "doc_render_smoke.tl",
        "tl_read" => "read.tl",
        "tl_reader" => "reader.tl",
        "tl_token" => "token.tl",
        _ => panic!("no TypeLisp source path configured for integration case {name}"),
    };
    manifest_dir.join("selfhost").join(selfhost_file)
}

fn dep_source_path(manifest_dir: &Path, source_dir: &Path, dep: &str) -> PathBuf {
    if dep == "sym_i64_env_core.tl" {
        return manifest_dir.join("selfhost").join("sym_i64_env.tl");
    }
    if dep == "format_doc.tl" {
        return manifest_dir.join("selfhost").join("format_doc.tl");
    }
    if dep == "format_cst.tl" {
        return manifest_dir.join("selfhost").join("format_cst.tl");
    }
    if dep == "format_core.tl" {
        return manifest_dir.join("selfhost").join("format_core.tl");
    }
    if dep == "format_rules.tl" {
        return manifest_dir.join("selfhost").join("format_rules.tl");
    }
    if dep == "format_tokens.tl" {
        return manifest_dir.join("selfhost").join("format_tokens.tl");
    }
    if dep == "text_buf_core.tl" {
        return manifest_dir.join("selfhost").join("text_buf.tl");
    }
    if dep == "stdlib/string.tl" {
        return manifest_dir.join("stdlib").join("string.tl");
    }
    if dep == "stdlib/test.tl" {
        return manifest_dir.join("stdlib").join("test.tl");
    }
    source_dir.join(dep)
}

fn copy_case_deps(manifest_dir: &Path, source_dir: &Path, work_dir: &Path, deps: &[&str]) {
    for dep in deps {
        let dep_src = dep_source_path(manifest_dir, source_dir, dep);
        let dep_dst = work_dir.join(dep);
        if let Some(parent) = dep_dst.parent() {
            fs::create_dir_all(parent).expect("create dep work dir");
        }
        fs::copy(&dep_src, &dep_dst).unwrap_or_else(|err| {
            panic!(
                "copy imported module {} from {} to {}: {}",
                dep,
                dep_src.display(),
                dep_dst.display(),
                err
            )
        });
    }
}

fn run_case_explicit_build(case: &Case) {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let source_path = source_path_for_case(&manifest_dir, case.name);
    let work_dir = manifest_dir
        .join("target")
        .join("integration-tests-explicit")
        .join(case.name);
    fs::create_dir_all(&work_dir).expect("create explicit build test work dir");
    let work_path = work_dir.join(format!("{}.tl", case.name));
    fs::copy(&source_path, &work_path).expect("copy TypeLisp program to work dir");

    // Copy any imported helper modules alongside the entry file.
    let source_dir = source_path.parent().expect("case source path has parent");
    copy_case_deps(&manifest_dir, source_dir, &work_dir, case.deps);

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
    let source_path = source_path_for_case(&manifest_dir, case.name);
    let work_dir = manifest_dir
        .join("target")
        .join("integration-tests")
        .join(case.name);
    fs::create_dir_all(&work_dir).expect("create integration test work dir");
    let work_path = work_dir.join(format!("{}.tl", case.name));
    fs::copy(&source_path, &work_path).expect("copy TypeLisp program to work dir");

    // Copy any imported helper modules alongside the entry file, preserving
    // their relative path so `(import "...")` resolves at load time.
    let source_dir = source_path.parent().expect("case source path has parent");
    copy_case_deps(&manifest_dir, source_dir, &work_dir, case.deps);

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

fn run_inline_source(work_name: &str, file_name: &str, source: &str) -> std::process::Output {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let work_dir = manifest_dir
        .join("target")
        .join("integration-tests")
        .join(work_name);
    fs::create_dir_all(&work_dir).expect("create inline test work dir");

    let work_path = work_dir.join(file_name);
    fs::write(&work_path, source).expect("write inline test source");

    Command::new(env!("CARGO_BIN_EXE_typelisp"))
        .arg("run")
        .arg(&work_path)
        .output()
        .expect("run inline typelisp test")
}

#[test]
fn source_file_build_writes_default_executable_without_running() {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let work_dir = manifest_dir
        .join("target")
        .join("integration-tests")
        .join("source_file_build_default");
    fs::create_dir_all(&work_dir).expect("create source build default test dir");
    let source = work_dir.join("main.tl");
    fs::write(
        &source,
        r#"
(define (main) : i64
  (begin
    (print-string "built\n")
    42))
"#,
    )
    .expect("write source build default fixture");

    let output = Command::new(env!("CARGO_BIN_EXE_typelisp"))
        .arg("build")
        .arg(&source)
        .output()
        .expect("run typelisp source build");

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        output.status.success(),
        "source build failed\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr
    );
    let bin_path = source.with_extension("");
    assert!(
        stdout.contains(&format!("Generated: {}", bin_path.display())),
        "source build stdout should name executable\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr
    );
    assert!(
        !stdout.contains("built"),
        "build should not run the compiled program\nstdout:\n{}",
        stdout
    );
    assert!(bin_path.exists(), "source build did not write executable");

    let run = Command::new(&bin_path)
        .output()
        .expect("run source-built executable");
    assert_eq!(
        run.status.code(),
        Some(42),
        "source-built executable exited unexpectedly\nstdout:\n{}\nstderr:\n{}",
        String::from_utf8_lossy(&run.stdout),
        String::from_utf8_lossy(&run.stderr)
    );
    assert_eq!(String::from_utf8_lossy(&run.stdout), "built\n");
}

#[test]
fn source_file_build_respects_explicit_output_path() {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let work_dir = manifest_dir
        .join("target")
        .join("integration-tests")
        .join("source_file_build_output");
    fs::create_dir_all(&work_dir).expect("create source build output test dir");
    let source = work_dir.join("main.tl");
    fs::write(&source, "(define (main) : i64 7)\n").expect("write source build output fixture");
    let bin_path = work_dir.join("nested").join("custom-app");

    let output = Command::new(env!("CARGO_BIN_EXE_typelisp"))
        .arg("build")
        .arg(&source)
        .arg("-o")
        .arg(&bin_path)
        .output()
        .expect("run typelisp source build with -o");

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        output.status.success(),
        "source build -o failed\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr
    );
    assert!(
        stdout.contains(&format!("Generated: {}", bin_path.display())),
        "source build -o stdout should name executable\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr
    );
    assert!(
        bin_path.exists(),
        "source build -o did not write executable"
    );

    let run = Command::new(&bin_path)
        .output()
        .expect("run explicit-output executable");
    assert_eq!(
        run.status.code(),
        Some(7),
        "explicit-output executable exited unexpectedly\nstdout:\n{}\nstderr:\n{}",
        String::from_utf8_lossy(&run.stdout),
        String::from_utf8_lossy(&run.stderr)
    );
}

const STDLIB_STRING_CONTAINS_PROGRAM: &str = r#"
(import "stdlib/string.tl")

(define (main) : i64
  (if (string-contains "hello" "ell") 42 1))
"#;

fn write_stdlib_string_import_fixture(work_dir: &Path, source: &str) -> PathBuf {
    fs::create_dir_all(work_dir).expect("create stdlib import fixture dir");
    let work_path = work_dir.join("main.tl");
    fs::write(&work_path, source).expect("write stdlib import fixture");
    work_path
}

fn assert_exit_code_without_output(output: &std::process::Output, expected: i32, context: &str) {
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert_eq!(
        output.status.code(),
        Some(expected),
        "{}\nstdout:\n{}\nstderr:\n{}",
        context,
        stdout,
        stderr,
    );
    assert_eq!(stdout, "", "{} wrote stdout", context);
    assert_eq!(stderr, "", "{} wrote stderr", context);
}

#[test]
fn stdlib_root_option_resolves_stdlib_import_without_staging() {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let work_dir = std::env::temp_dir().join(format!(
        "typelisp-stdlib-root-lookup-{}",
        std::process::id()
    ));

    let work_path = write_stdlib_string_import_fixture(&work_dir, STDLIB_STRING_CONTAINS_PROGRAM);

    let output = Command::new(env!("CARGO_BIN_EXE_typelisp"))
        .arg("run")
        .arg(&work_path)
        .arg("--stdlib-root")
        .arg(manifest_dir.join("stdlib"))
        .output()
        .expect("run stdlib-root lookup fixture");

    assert_exit_code_without_output(&output, 42, "stdlib-root fixture exited unexpectedly");
}

#[test]
fn stdlib_root_env_resolves_stdlib_import_without_staging() {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let work_dir =
        std::env::temp_dir().join(format!("typelisp-stdlib-env-lookup-{}", std::process::id()));

    let work_path = write_stdlib_string_import_fixture(&work_dir, STDLIB_STRING_CONTAINS_PROGRAM);

    let output = Command::new(env!("CARGO_BIN_EXE_typelisp"))
        .arg("run")
        .arg(&work_path)
        .env("TYPELISP_STDLIB_ROOT", manifest_dir.join("stdlib"))
        .output()
        .expect("run stdlib env lookup fixture");

    assert_exit_code_without_output(&output, 42, "stdlib env fixture exited unexpectedly");
}

#[test]
fn stdlib_root_option_precedes_env_fallback() {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let work_dir = std::env::temp_dir().join(format!(
        "typelisp-stdlib-root-precedes-env-{}",
        std::process::id()
    ));
    let stale_root = work_dir.join("stale-stdlib");
    fs::create_dir_all(&stale_root).expect("create stale stdlib root");
    fs::write(stale_root.join("string.tl"), "(define broken").expect("write stale stdlib file");

    let work_path = write_stdlib_string_import_fixture(&work_dir, STDLIB_STRING_CONTAINS_PROGRAM);

    let output = Command::new(env!("CARGO_BIN_EXE_typelisp"))
        .arg("run")
        .arg(&work_path)
        .arg("--stdlib-root")
        .arg(manifest_dir.join("stdlib"))
        .env("TYPELISP_STDLIB_ROOT", &stale_root)
        .output()
        .expect("run explicit stdlib root with stale env fallback");

    assert_exit_code_without_output(
        &output,
        42,
        "explicit stdlib root did not precede env fallback",
    );
}

#[test]
fn local_stdlib_import_precedes_env_fallback() {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let work_dir = std::env::temp_dir().join(format!(
        "typelisp-local-stdlib-precedes-env-{}",
        std::process::id()
    ));
    let local_stdlib_dir = work_dir.join("stdlib");
    fs::create_dir_all(&local_stdlib_dir).expect("create local stdlib fixture dir");
    fs::write(
        local_stdlib_dir.join("string.tl"),
        "(define (local-stdlib-value) : i64 42)\n",
    )
    .expect("write local stdlib fixture");

    let work_path = write_stdlib_string_import_fixture(
        &work_dir,
        r#"
(import "stdlib/string.tl")

(define (main) : i64
  (local-stdlib-value))
"#,
    );

    let output = Command::new(env!("CARGO_BIN_EXE_typelisp"))
        .arg("run")
        .arg(&work_path)
        .env("TYPELISP_STDLIB_ROOT", manifest_dir.join("stdlib"))
        .output()
        .expect("run local stdlib precedence fixture");

    assert_exit_code_without_output(
        &output,
        42,
        "local stdlib import did not precede env fallback",
    );
}

#[test]
fn stdlib_root_env_resolves_compile_without_staging() {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let work_dir = std::env::temp_dir().join(format!(
        "typelisp-stdlib-env-compile-{}",
        std::process::id()
    ));
    let output_path = work_dir.join("main.ir");

    let work_path = write_stdlib_string_import_fixture(&work_dir, STDLIB_STRING_CONTAINS_PROGRAM);

    let output = Command::new(env!("CARGO_BIN_EXE_typelisp"))
        .arg("compile")
        .arg(&work_path)
        .arg("--emit-ir")
        .arg("-o")
        .arg(&output_path)
        .env("TYPELISP_STDLIB_ROOT", manifest_dir.join("stdlib"))
        .output()
        .expect("compile stdlib env lookup fixture");

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        output.status.success(),
        "stdlib env compile failed\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr,
    );
    assert!(
        output_path.exists(),
        "stdlib env compile did not write IR output"
    );
    assert_eq!(stderr, "", "stdlib env compile wrote stderr");
}

#[test]
fn stdlib_test_failing_assertion_reports_message() {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let work_dir =
        std::env::temp_dir().join(format!("typelisp-stdlib-test-fail-{}", std::process::id()));
    fs::create_dir_all(&work_dir).expect("create stdlib test failure work dir");
    let work_path = work_dir.join("main.tl");
    fs::write(
        &work_path,
        r#"
(import "stdlib/test.tl")

(define (main) : i64
  (begin
    (assert-i64-eq 1 2 "stdlib test failure message")
    0))
"#,
    )
    .expect("write stdlib test failure fixture");

    let output = Command::new(env!("CARGO_BIN_EXE_typelisp"))
        .arg("run")
        .arg(&work_path)
        .arg("--stdlib-root")
        .arg(manifest_dir.join("stdlib"))
        .output()
        .expect("run stdlib test failure fixture");

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert_eq!(
        output.status.code(),
        Some(134),
        "failing stdlib assertion should abort with status 134\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr,
    );
    assert_eq!(stdout, "", "failing stdlib assertion wrote stdout");
    assert!(
        stderr.contains("stdlib test failure message"),
        "failing stdlib assertion did not report caller message\nstderr:\n{}",
        stderr,
    );
}

#[test]
fn stdlib_root_env_appears_in_missing_import_diagnostic() {
    let work_dir = std::env::temp_dir().join(format!(
        "typelisp-stdlib-env-missing-diag-{}",
        std::process::id()
    ));
    let env_root = work_dir.join("env-stdlib");
    fs::create_dir_all(&env_root).expect("create env stdlib root");

    let work_path = write_stdlib_string_import_fixture(
        &work_dir,
        r#"
(import "stdlib/not-here.tl")

(define (main) : i64
  0)
"#,
    );

    let output = Command::new(env!("CARGO_BIN_EXE_typelisp"))
        .arg("check")
        .arg(&work_path)
        .env("TYPELISP_STDLIB_ROOT", &env_root)
        .output()
        .expect("check missing stdlib env lookup fixture");

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        !output.status.success(),
        "missing stdlib check unexpectedly succeeded\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr,
    );
    assert!(
        stderr.contains("searched stdlib roots"),
        "missing stdlib diagnostic did not mention searched roots\nstderr:\n{}",
        stderr,
    );
    assert!(
        stderr.contains(&env_root.display().to_string()),
        "missing stdlib diagnostic did not include env root {}\nstderr:\n{}",
        env_root.display(),
        stderr,
    );
}

#[test]
fn stdlib_root_env_rejects_parent_dir_escape() {
    let base_dir =
        std::env::temp_dir().join(format!("typelisp-stdlib-env-escape-{}", std::process::id()));
    let work_dir = base_dir.join("work");
    let env_parent = base_dir.join("env");
    let env_root = env_parent.join("stdlib");
    fs::create_dir_all(&env_root).expect("create env stdlib root");
    fs::write(
        env_parent.join("outside.tl"),
        "(define (escaped) : i64 42)\n",
    )
    .expect("write escaped sibling fixture");

    let work_path = write_stdlib_string_import_fixture(
        &work_dir,
        r#"
(import "stdlib/../outside.tl")

(define (main) : i64
  (escaped))
"#,
    );

    let output = Command::new(env!("CARGO_BIN_EXE_typelisp"))
        .arg("check")
        .arg(&work_path)
        .env("TYPELISP_STDLIB_ROOT", &env_root)
        .output()
        .expect("check stdlib env escape fixture");

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        !output.status.success(),
        "stdlib env escape check unexpectedly succeeded\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr,
    );
    assert!(
        stderr.contains("stdlib/../outside.tl"),
        "stdlib env escape diagnostic did not include import path\nstderr:\n{}",
        stderr,
    );
    assert!(
        stderr.contains("searched stdlib roots"),
        "stdlib env escape diagnostic did not mention searched roots\nstderr:\n{}",
        stderr,
    );
    assert!(
        stderr.contains(&env_root.display().to_string()),
        "stdlib env escape diagnostic did not include env root {}\nstderr:\n{}",
        env_root.display(),
        stderr,
    );
}

#[test]
fn make_array_negative_length_traps_before_alloc() {
    let output = run_inline_source(
        "make_array_negative_length_trap",
        "make_array_negative_length_trap.tl",
        r#"
(define (main) : i64
  (begin
    (make-array i64 -1)
    0))
"#,
    );

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert_eq!(
        output.status.code(),
        Some(134),
        "negative make-array length should abort 134\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr
    );
    assert_eq!(stdout, "", "make-array length trap should not write stdout");
    assert_eq!(
        stderr, "tl: array index out of bounds\n",
        "negative make-array length should trap before tl_alloc"
    );
}

#[test]
fn make_array_byte_count_overflow_traps_before_alloc() {
    let output = run_inline_source(
        "make_array_overflow_trap",
        "make_array_overflow_trap.tl",
        r#"
(define (main) : i64
  (begin
    (make-array i64 1152921504606846976)
    0))
"#,
    );

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert_eq!(
        output.status.code(),
        Some(134),
        "overflowing make-array byte count should abort 134\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr
    );
    assert_eq!(
        stdout, "",
        "make-array overflow trap should not write stdout"
    );
    assert_eq!(
        stderr, "tl: array index out of bounds\n",
        "overflowing make-array length should trap before tl_alloc"
    );
}

#[test]
fn make_array_zero_length_reports_zero() {
    let output = run_inline_source(
        "make_array_zero_length",
        "make_array_zero_length.tl",
        r#"
(define (main) : i64
  (let ([a : (Array i64) (make-array i64 0)])
    (length a)))
"#,
    );

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert_eq!(
        output.status.code(),
        Some(0),
        "zero-length make-array should return length 0\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr
    );
    assert_eq!(stdout, "", "zero-length make-array should not write stdout");
    assert_eq!(stderr, "", "zero-length make-array should not write stderr");
}

// refs #205: calling the raw allocator with an impossible-size request
// (`u64` -1, i.e. 0xFFFFFFFFFFFFFFFF) triggers the allocation-failure trap
// and terminates with the abort status 134 rather than crashing or returning
// an invalid pointer.
#[test]
fn tl_alloc_huge_request_traps_abort_134() {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let work_dir = manifest_dir
        .join("target")
        .join("integration-tests")
        .join("tl_alloc_trap");
    fs::create_dir_all(&work_dir).expect("create tl_alloc trap test work dir");

    let source = r#"
(extern tl_alloc : (-> u64 u64))

;; Cast -1 to u64 to get the max value (0xFFFFFFFFFFFFFFFF)
(define (main) : u64
  (tl_alloc (cast -1 : u64)))
"#;
    let work_path = work_dir.join("tl_alloc_trap.tl");
    fs::write(&work_path, source).expect("write tl_alloc trap source");

    let output = Command::new(env!("CARGO_BIN_EXE_typelisp"))
        .arg("run")
        .arg(&work_path)
        .output()
        .expect("run tl_alloc trap test");

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert_eq!(
        output.status.code(),
        Some(134),
        "tl_alloc with huge size should abort 134, not succeed\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr,
    );
    assert_eq!(stdout, "", "tl_alloc trap should not write stdout");
    assert_eq!(
        stderr, "tl: allocation failed\n",
        "tl_alloc trap should write the allocation diagnostic"
    );
}

#[test]
fn region_mark_before_allocation_returns_zero() {
    let output = run_inline_source(
        "region_mark_before_alloc",
        "region_mark_before_alloc.tl",
        r#"
(extern tl_region_mark : (-> u64))

(define (main) : i64
  (if (= (tl_region_mark) (cast 0 : u64)) 42 1))
"#,
    );

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert_eq!(
        output.status.code(),
        Some(42),
        "region mark before allocation should return zero\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr
    );
    assert_eq!(stdout, "", "region mark should not write stdout");
    assert_eq!(stderr, "", "region mark should not write stderr");
}

#[test]
fn region_reset_zero_clears_all_arenas() {
    let output = run_inline_source(
        "region_reset_zero",
        "region_reset_zero.tl",
        r#"
(extern tl_region_mark : (-> u64))
(extern tl_region_reset : (-> u64 unit))

(define (main) : i64
  (begin
    (string-append "left" "right")
    (tl_region_reset (cast 0 : u64))
    (if (= (tl_region_mark) (cast 0 : u64)) 44 1)))
"#,
    );

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert_eq!(
        output.status.code(),
        Some(44),
        "region reset zero should clear all arenas\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr
    );
    assert_eq!(stdout, "", "region reset zero should not write stdout");
    assert_eq!(stderr, "", "region reset zero should not write stderr");
}

#[test]
fn region_reset_preserves_pre_mark_allocations() {
    let output = run_inline_source(
        "region_reset_preserves_pre_mark",
        "region_reset_preserves_pre_mark.tl",
        r#"
(extern tl_region_mark : (-> u64))
(extern tl_region_reset : (-> u64 unit))

(defenum Box (Boxed i64))
(defstruct Pair (x i64) (y i64))

(define (make-box [n : i64]) : Box
  (Boxed n))

(define (make-pair [x : i64] [y : i64]) : Pair
  (Pair x y))

(define (box-value [b : Box]) : i64
  (match b
    [(Boxed n) n]))

(define (cycle [n : i64]) : unit
  (let ([m : u64 (tl_region_mark)])
    (begin
      (string-append "tmp" (int->string n))
      (tl_region_reset m))))

(define (main) : i64
  (let ([s : String (string-append "a" "b")]
        [arr : (Array i64) (make-array i64 2)]
        [box : Box (make-box 7)]
        [pair : Pair (make-pair 5 6)]
        [m : u64 (tl_region_mark)])
    (begin
      (array-set! arr 0 20)
      (array-set! arr 1 22)
      (string-append "temporary" (int->string 99))
      (tl_region_reset m)
      (cycle 1)
      (cycle 2)
      (+ (string-length s)
         (+ (array-ref arr 0)
            (+ (array-ref arr 1)
               (+ (box-value box)
                  (+ (struct-get pair x)
                     (struct-get pair y)))))))))
"#,
    );

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert_eq!(
        output.status.code(),
        Some(62),
        "region reset should preserve values allocated before the mark\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr
    );
    assert_eq!(
        stdout, "",
        "region reset preserve test should not write stdout"
    );
    assert_eq!(
        stderr, "",
        "region reset preserve test should not write stderr"
    );
}

#[test]
fn region_reset_discards_post_mark_arenas() {
    let output = run_inline_source(
        "region_reset_discards_post_mark_arenas",
        "region_reset_discards_post_mark_arenas.tl",
        r#"
(extern tl_alloc : (-> u64 u64))
(extern tl_region_mark : (-> u64))
(extern tl_region_reset : (-> u64 unit))

(define (main) : i64
  (let ([before : String (string-append "a" "b")]
        [m : u64 (tl_region_mark)])
    (begin
      (tl_alloc (cast 67108864 : u64))
      (tl_region_reset m)
      (string-length (string-append before "c")))))
"#,
    );

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert_eq!(
        output.status.code(),
        Some(3),
        "region reset should discard arenas allocated after the mark\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr
    );
    assert_eq!(stdout, "", "post-mark arena test should not write stdout");
    assert_eq!(stderr, "", "post-mark arena test should not write stderr");
}

#[test]
fn region_reset_invalid_mark_traps_abort_134() {
    let output = run_inline_source(
        "region_reset_invalid_mark",
        "region_reset_invalid_mark.tl",
        r#"
(extern tl_region_reset : (-> u64 unit))

(define (main) : i64
  (begin
    (tl_region_reset (cast 1234 : u64))
    0))
"#,
    );

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert_eq!(
        output.status.code(),
        Some(134),
        "invalid region mark should abort 134\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr
    );
    assert_eq!(stdout, "", "invalid region mark should not write stdout");
    assert_eq!(
        stderr, "tl: invalid region mark\n",
        "invalid region mark stderr differed"
    );
}

#[test]
fn division_by_zero_traps_with_diagnostic() {
    let output = run_inline_source(
        "div_zero_trap",
        "div_zero_trap.tl",
        r#"
(define (main) : i64
  (begin
    (/ 1 0)
    0))
"#,
    );

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert_eq!(
        output.status.code(),
        Some(135),
        "division by zero should abort 135\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr
    );
    assert_eq!(stdout, "", "div-zero trap should not write stdout");
    assert_eq!(
        stderr, "tl: integer division or remainder error\n",
        "div-zero trap stderr differed"
    );
}

#[test]
fn remainder_by_zero_traps_with_diagnostic() {
    let output = run_inline_source(
        "rem_zero_trap",
        "rem_zero_trap.tl",
        r#"
(define (main) : i64
  (begin
    (% 1 0)
    0))
"#,
    );

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert_eq!(
        output.status.code(),
        Some(135),
        "remainder by zero should abort 135\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr
    );
    assert_eq!(stdout, "", "rem-zero trap should not write stdout");
    assert_eq!(
        stderr, "tl: integer division or remainder error\n",
        "rem-zero trap stderr differed"
    );
}

#[test]
fn signed_min_divided_by_neg_one_traps() {
    let output = run_inline_source(
        "min_div_neg1_trap",
        "min_div_neg1_trap.tl",
        r#"
(define (main) : i64
  (begin
    (/ -9223372036854775808 -1)
    0))
"#,
    );

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert_eq!(
        output.status.code(),
        Some(135),
        "signed MIN / -1 should abort 135\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr
    );
    assert_eq!(stdout, "", "MIN/-1 trap should not write stdout");
    assert_eq!(
        stderr, "tl: integer division or remainder error\n",
        "MIN/-1 trap stderr differed"
    );
}

#[test]
fn signed_i16_min_divided_by_neg_one_traps() {
    let output = run_inline_source(
        "i16_min_div_neg1_trap",
        "i16_min_div_neg1_trap.tl",
        r#"
(define (main) : i64
  (begin
    (/ (cast -32768 : i16) (cast -1 : i16))
    0))
"#,
    );

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert_eq!(
        output.status.code(),
        Some(135),
        "i16 MIN / -1 should abort 135\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr
    );
    assert_eq!(stdout, "", "i16 MIN/-1 trap should not write stdout");
    assert_eq!(
        stderr, "tl: integer division or remainder error\n",
        "i16 MIN/-1 trap stderr differed"
    );
}

#[test]
fn signed_i16_min_remainder_by_neg_one_traps() {
    let output = run_inline_source(
        "i16_min_rem_neg1_trap",
        "i16_min_rem_neg1_trap.tl",
        r#"
(define (main) : i64
  (begin
    (% (cast -32768 : i16) (cast -1 : i16))
    0))
"#,
    );

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert_eq!(
        output.status.code(),
        Some(135),
        "i16 MIN % -1 should abort 135\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr
    );
    assert_eq!(stdout, "", "i16 MIN%-1 trap should not write stdout");
    assert_eq!(
        stderr, "tl: integer division or remainder error\n",
        "i16 MIN%-1 trap stderr differed"
    );
}

#[test]
fn unsigned_u16_division_by_zero_traps() {
    let output = run_inline_source(
        "u16_div_zero_trap",
        "u16_div_zero_trap.tl",
        r#"
(define (main) : i64
  (begin
    (/ (cast 1 : u16) (cast 0 : u16))
    0))
"#,
    );

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert_eq!(
        output.status.code(),
        Some(135),
        "u16 division by zero should abort 135\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr
    );
    assert_eq!(stdout, "", "u16 div-zero trap should not write stdout");
    assert_eq!(
        stderr, "tl: integer division or remainder error\n",
        "u16 div-zero trap stderr differed"
    );
}

#[test]
fn shift_count_equal_to_width_traps() {
    let output = run_inline_source(
        "shl_count_width_trap",
        "shl_count_width_trap.tl",
        r#"
(define (main) : i64
  (begin
    (shl 1 64)
    0))
"#,
    );

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert_eq!(
        output.status.code(),
        Some(129),
        "shl count == width should abort 129\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr
    );
    assert_eq!(stdout, "", "shl-width trap should not write stdout");
    assert_eq!(
        stderr, "tl: shift count out of range\n",
        "shl-width trap stderr differed"
    );
}

#[test]
fn shift_negative_count_traps() {
    let output = run_inline_source(
        "shl_neg_count_trap",
        "shl_neg_count_trap.tl",
        r#"
(define (main) : i64
  (begin
    (shl 1 -1)
    0))
"#,
    );

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert_eq!(
        output.status.code(),
        Some(129),
        "shl negative count should abort 129\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr
    );
    assert_eq!(stdout, "", "shl-neg trap should not write stdout");
    assert_eq!(
        stderr, "tl: shift count out of range\n",
        "shl-neg trap stderr differed"
    );
}

#[test]
fn valid_shifts_at_zero_and_max_counts() {
    let output = run_inline_source(
        "valid_shift_counts",
        "valid_shift_counts.tl",
        r#"
(define (main) : i64
  (begin
    (let ([i64-zero : i64 (shl 1 0)])
    (let ([i64-max : i64 (shr 1 63)])
    (let ([u64-max : u64 (shr (cast -1 : u64) 63)])
    (let ([u8-max : u8 (shr (cast 128 : u8) (cast 7 : u8))])
      (if (and (and (= i64-zero 1) (= i64-max 0))
               (and (= u64-max (cast 1 : u64)) (= u8-max (cast 1 : u8))))
        42
        1)))))))
"#,
    );

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert_eq!(
        output.status.code(),
        Some(42),
        "valid shifts should exit 42\nstdout:\n{}\nstderr:\n{}",
        stdout,
        stderr
    );
    assert_eq!(stdout, "", "valid shifts should not write stdout");
    assert_eq!(stderr, "", "valid shifts should not write stderr");
}
