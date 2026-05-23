;; tl_parse.tl - The s-expression PARSER that completes the end-to-end
;; self-hosted compiler pipeline: `lex -> read -> parse -> emit-program` turns
;; SOURCE TEXT into a runnable x86_64 `.s`, all in TypeLisp (#154).
;;
;; --------------------------------------------------------------------------
;; Where this sits in the front end.
;; --------------------------------------------------------------------------
;; The reader (`tl_read.tl`) turns the lexer's token stream into the generic
;; cons-cell `Sexpr` tree the parens describe - it knows nothing about which
;; symbols are operators. The BACKEND (`tl_emit.tl`) lowers a tiny, TYPED
;; arithmetic `Expr` AST (`(EInt n)` / `(EBin op a b)`) to x86_64 text. This
;; module is the missing middle: `parse : Sexpr -> Expr` recognises the
;; arithmetic SUBSET of s-expressions and projects it onto that `Expr` AST, so
;;
;;   String --lex--> (Array Token) --read--> Sexpr --parse--> Expr --emit--> .s
;;
;; becomes a single composition. `main` runs the WHOLE pipeline on the literal
;; source string "(+ 1 (* 2 3))" and prints the complete runnable `.s`; assembled
;; (`as`) + linked (`ld`) + run, that `.s` EXITS 7 - the same value the emitter
;; proved, now reached THROUGH lex -> read -> parse.
;;
;; --------------------------------------------------------------------------
;; The import decision: import shared AST types + reader, duplicate emitter helpers.
;; --------------------------------------------------------------------------
;; `tl_read.tl` is a `main`-less module (refs #44): `(import "tl_read.tl")` pulls
;; in `lex`, `read`, and the `Sexpr` AST (it transitively imports the `main`-less
;; `tl_lex.tl` + `tl_token.tl`). The module loader is whole-program-concatenation,
;; so it copies all imported declarations into one program before typecheck ->
;; lower -> codegen. That import is clean BECAUSE none of those modules declares a
;; `main`.
;;
;; The shared `tl_ast_types.tl` module is also `main`-less, so `BinOp` / `Expr`
;; come from the same AST definition used by `tl_emit.tl`.
;;
;; The backend `tl_emit.tl`, by contrast, is a runnable DEMO and carries its own
;; `main`. Importing it here - where we ALSO need a `main` to drive the pipeline -
;; would concatenate two `main`s into one program and clash on the duplicate
;; symbol (the known module limitation documented in tl_read.tl). So only the
;; `emit-*` / `emit-program` helpers are duplicated below, pending a shared
;; `main`-less emitter module (see #27). This is the same trade-off tl_eval.tl
;; took: import the `main`-less front end, keep the `main`-bearing piece separate.
;; The result COMPILES with exactly one `main` (this file's) and runs the real
;; pipeline.
;;
;; `string-eq` (used by `parse-op`) is a host builtin (see its many uses in
;; tl_eval.tl), not a module export, so it needs no import.

(import "tl_ast_types.tl")
(import "tl_read.tl")

;; ==========================================================================
;; Duplicated from tl_emit.tl (#155/#156) pending a shared module (see #27).
;; The x86_64 emitter helpers. The AST comes from `tl_ast_types.tl`.
;; ==========================================================================

(define (emit-int [n : i64]) : String
  (string-append "    movq $" (string-append (int->string n) ", %rax\n")))

(define (emit-op [op : BinOp]) : String
  (match op
    [(OpAdd) "    addq %rcx, %rax\n"]
    [(OpSub) "    subq %rcx, %rax\n"]
    [(OpMul) "    imulq %rcx, %rax\n"]))

(define (emit-bin [op : BinOp] [a : Expr] [b : Expr]) : String
  (string-append (emit-expr a)
    (string-append "    pushq %rax\n"
      (string-append (emit-expr b)
        (string-append "    movq %rax, %rcx\n"
          (string-append "    popq %rax\n"
            (emit-op op)))))))

(define (emit-expr [e : Expr]) : String
  (match e
    [(EInt n) (emit-int n)]
    [(EVar _) (begin (panic "emit: variables are not in M1 arithmetic") "")]
    [(EBin op a b) (emit-bin op a b)]
    [(ECall _ _) (begin (panic "emit: calls are not in M1 arithmetic") "")]))

(define (emit-program [e : Expr]) : String
  (string-append "    .text\n"
    (string-append "    .globl main\n"
      (string-append "    .globl _start\n\n"
        (string-append "main:\n"
          (string-append "    push %rbp\n"
            (string-append "    mov %rsp, %rbp\n"
              (string-append (emit-expr e)
                (string-append "    pop %rbp\n"
                  (string-append "    ret\n\n"
                    (string-append "_start:\n"
                      (string-append "    call main\n"
                        (string-append "    movq %rax, %rdi\n"
                          (string-append "    movq $60, %rax\n"
                            "    syscall\n"))))))))))))))

;; ==========================================================================
;; The PARSER: `Sexpr -> Expr`, the new contribution of this module (#154).
;; ==========================================================================

;; parse-op: resolve an operator SYMBOL's text to its `BinOp` tag. The arithmetic
;; surface recognises exactly `+`, `-`, `*`, dispatched byte-wise on the lexeme
;; with the host `string-eq` (the same builtin tl_eval.tl uses for operator
;; dispatch). Any other head symbol is not part of the recognised arithmetic
;; subset, so it is a MALFORMED program: abort via the `panic` builtin (#45) -
;; the codebase's channel for malformed input, exactly as the reader uses it.
;; `panic` never returns, but the trailing `(OpAdd)` gives the `if` a `BinOp` so
;; the function typechecks.
(define (parse-op [op : String]) : BinOp
  (if (string-eq op "+")
      (OpAdd)
      (if (string-eq op "-")
          (OpSub)
          (if (string-eq op "*")
              (OpMul)
              (begin
                (panic "parse: unknown operator")
                (OpAdd))))))

;; parse: project the arithmetic SUBSET of the generic `Sexpr` tree onto the
;; typed `Expr` AST the emitter consumes.
;;   (SInt n)                                 -> (EInt n)              an int leaf
;;   (SCons (SSym op) (SCons a (SCons b (SNil)))) -> (EBin (parse-op op)
;;                                                          (parse a) (parse b))
;; i.e. exactly a proper 3-element list whose head is a symbol: an operator
;; applied to two operand sub-expressions, each parsed recursively (so nesting
;; like `(* 2 3)` inside `(+ 1 ...)` is handled for free). Anything else - a bare
;; symbol, a string atom, the empty list, a list of the wrong shape/arity, or an
;; operator applied to non-two operands - is OUTSIDE the recognised arithmetic
;; subset and therefore a MALFORMED program: abort via `panic`, keeping `parse`
;; TOTAL (it returns an `Expr` on every well-formed input and never otherwise) and
;; directly composable as `(emit-program (parse (read (lex src))))`. The trailing
;; `(EInt 0)` is unreachable dead code that gives the fall-through `match` arm an
;; `Expr` so the function typechecks.
(define (parse [s : Sexpr]) : Expr
  (match s
    [(SInt n) (EInt n)]
    [(SCons (SSym op) (SCons a (SCons b (SNil))))
     (EBin (parse-op op) (parse a) (parse b))]
    [_ (begin
         (panic "parse: malformed expression")
         (EInt 0))]))

;; main: run the WHOLE self-hosted pipeline end to end on a literal source string
;; and PRINT the complete runnable `.s`. `lex` tokenises the text, `read` builds
;; the `Sexpr` cons tree, `parse` projects it onto the `Expr` AST, and
;; `emit-program` lowers that to a full backend-shaped `.s`. For "(+ 1 (* 2 3))"
;; the emitted program, when assembled + linked + run, exits 7 - so this single
;; line takes SOURCE TEXT to machine code that runs and returns 7, the headline
;; of #154. The Linux-gated integration test assembles the printed text and
;; asserts exit status 7; the printed `.s` is byte-identical to tl_emit's, since
;; both compute `(+ 1 (* 2 3))`.
(define (main) : unit
  (print-string (emit-program (parse (read (lex "(+ 1 (* 2 3))"))))))
