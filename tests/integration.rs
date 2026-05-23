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

const TL_EMIT_BODY_ASM: &str = concat!(
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
        // Self-hosting M1 (#155): the first backend-shaped TypeLisp emitter.
        // `tl_emit.tl` builds the arithmetic Expr tree `(+ 1 (* 2 3))`, walks it
        // with `emit-expr`, and prints the body assembly text. This test asserts
        // the exact printed stack-machine instruction sequence; wrapping it in a
        // full `_start`/`main` skeleton is the follow-up driver issue (#156).
        Case {
            name: "tl_emit",
            exit_code: 0,
            stdout: TL_EMIT_BODY_ASM,
            deps: &[],
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
        // Self-hosting M1 (#155): the TypeLisp emitter for the arithmetic Expr
        // subset, also through the explicit compile -> as -> ld -> run pipeline.
        // It prints exactly the stack-machine body assembly for `(+ 1 (* 2 3))`.
        Case {
            name: "tl_emit",
            exit_code: 0,
            stdout: TL_EMIT_BODY_ASM,
            deps: &[],
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
        // model) is reused via the `main`-less `tl_read.tl` import - including its
        // lower-level `read-form` cursor entry, which the program reader drives to
        // read all top-level forms; all three imported modules are copied alongside
        // so the imports resolve.
        Case {
            name: "tl_eval",
            exit_code: 30,
            stdout: "hello world3233\n25\n15\n2\n10\n1\n0\n1\n3\n(1 2 3)(1 (2 3) 4)(10 . 20)(1 2 . 3)(1 4 9 16)(1 2)",
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
        // refs #42: Immutable scoped String -> i64 symbol table through the
        // explicit compile -> as -> ld -> run pipeline.
        Case {
            name: "sym_i64_env",
            exit_code: 0,
            stdout: "PASS: empty-miss\nPASS: single-hit-contains\nPASS: single-hit-value\nPASS: single-miss\nPASS: shadow-newest\nPASS: outer-preserved-a\nPASS: outer-no-b\nPASS: inner-sees-a\nPASS: inner-sees-b\nPASS: substring-key-hit\nPASS: append-key-hit\nPASS: chain-x\nPASS: chain-y\nPASS: chain-z\nAll sym-i64-env tests passed.\n",
            deps: &["sym_i64_env_core.tl"],
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
