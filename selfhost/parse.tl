;; parse.tl - Runnable demo for the self-hosted parser/emitter pipeline.
;;
;; --------------------------------------------------------------------------
;; Where this sits in the front end.
;; --------------------------------------------------------------------------
;; `parse_core.tl` holds the reusable `Sexpr -> Expr` parser definitions. This
;; file keeps the original demo shape: `main` runs
;; `lex -> read -> parse -> emit-program` on an embedded source string and prints
;; the generated runnable `.s` when parsing succeeds.
;;
(import "parse_core.tl")

;; main: run the whole self-hosted pipeline on a source string that exercises
;; let, if, and comparison lowering.
(define (main) : unit
  (match (parse (read (lex "(let ((x 5)) (if (<= x 5) 1 0))")))
    [(OkExpr expr) (print-string (emit-program expr))]
    [(ErrExpr message) (panic message)]))