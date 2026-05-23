;; tl_parse.tl - The s-expression PARSER that completes the end-to-end
;; self-hosted compiler pipeline: `lex -> read -> parse -> emit-program` turns
;; SOURCE TEXT into a runnable x86_64 `.s`, all in TypeLisp (#154).
;;
;; --------------------------------------------------------------------------
;; Where this sits in the front end.
;; --------------------------------------------------------------------------
;; The reader (`tl_read.tl`) turns the lexer's token stream into the generic
;; cons-cell `Sexpr` tree the parens describe - it knows nothing about which
;; symbols are operators. The BACKEND (`tl_emit_core.tl`) lowers a tiny, TYPED
;; arithmetic `Expr` AST (`(EInt n)` / `(EBin op a b)`) to x86_64 text. This
;; module is the missing middle: `parse : Sexpr -> Expr` recognises the
;; arithmetic SUBSET of s-expressions and projects it onto that `Expr` AST, so
;;
;;   String --lex--> (Array Token) --read--> Sexpr --parse--> Expr --emit--> .s
;;
;; becomes a single composition. `main` runs the WHOLE pipeline on a single-let
;; source string and prints the complete runnable `.s`; assembled (`as`) + linked
;; (`ld`) + run, that `.s` EXITS 7 - the same value the emitter proved, now
;; reached THROUGH lex -> read -> parse.
;;
;; --------------------------------------------------------------------------
;; The import decision: import main-less reader + emitter modules.
;; --------------------------------------------------------------------------
;; `tl_read.tl` is a `main`-less module (refs #44): `(import "tl_read.tl")` pulls
;; in `lex`, `read`, and the `Sexpr` AST (it transitively imports the `main`-less
;; `tl_lex.tl` + `tl_token.tl`). The module loader is whole-program-concatenation,
;; so it copies all imported declarations into one program before typecheck ->
;; lower -> codegen. That import is clean BECAUSE none of those modules declares a
;; `main`.
;;
;; The shared `tl_emit_core.tl` module is also `main`-less and imports
;; `tl_ast_types.tl`, so `BinOp` / `Expr` and `emit-program` come from the same
;; definitions used by `tl_emit.tl`.
;;
;; `tl_emit.tl`, by contrast, is a runnable DEMO and carries its own `main`.
;; Importing the core emitter here avoids concatenating two `main`s into one
;; program. The result COMPILES with exactly one `main` (this file's) and runs
;; the real pipeline.
;;
;; `string-eq` (used by `parse-op`) is a host builtin (see its many uses in
;; tl_eval.tl), not a module export, so it needs no import.

(import "tl_emit_core.tl")
(import "tl_read.tl")

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
              (if (string-eq op "<")
                  (OpLt)
                  (if (string-eq op "=")
                      (OpEq)
                      (begin
                        (panic "parse: unknown operator")
                        (OpAdd))))))))

(define (parse-binary [op : BinOp] [rest : Sexpr]) : Expr
  (match rest
    [(SCons a (SCons b (SNil))) (EBin op (parse a) (parse b))]
    [_ (begin
         (panic "parse: malformed binary expression")
         (EInt 0))]))

(define (parse-let [rest : Sexpr]) : Expr
  (match rest
    [(SCons (SCons (SCons (SSym name) (SCons value (SNil))) (SNil))
            (SCons body (SNil)))
     (ELet name (parse value) (parse body))]
    [_ (begin
         (panic "parse: malformed let")
         (EInt 0))]))

;; parse-if (#167): project `(if c t e)` onto `(EIf c t e)`. The argument spine
;; must be exactly three forms; anything else is malformed input.
(define (parse-if [rest : Sexpr]) : Expr
  (match rest
    [(SCons c (SCons t (SCons e (SNil))))
     (EIf (parse c) (parse t) (parse e))]
    [_ (begin
         (panic "parse: malformed if")
         (EInt 0))]))

;; parse: project the small source subset onto the typed `Expr` AST the emitter
;; consumes: ints, variables, binary arithmetic, and one-binding `let`.
;; Malformed input aborts via `panic`; the trailing `(EInt 0)` arms are
;; unreachable dead code that give fall-through branches an `Expr`.
(define (parse [s : Sexpr]) : Expr
  (match s
    [(SInt n) (EInt n)]
    [(SSym name) (EVar name)]
    [(SCons (SSym op) rest)
     (if (string-eq op "let")
         (parse-let rest)
         (if (string-eq op "if")
             (parse-if rest)
             (parse-binary (parse-op op) rest)))]
    [_ (begin
         (panic "parse: malformed expression")
         (EInt 0))]))

;; main: run the whole self-hosted pipeline on a source string that exercises
;; let, if, and comparison lowering.
(define (main) : unit
  (print-string (emit-program (parse (read (lex "(let ((x 5)) (if (< x 10) 1 0))"))))))
