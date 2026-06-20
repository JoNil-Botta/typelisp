;; lex_span_smoke.tl - Runnable smoke for the spanned token stream (#599).
;;
;; Lexes a multi-line, nested source and checks that each token carries the
;; correct 1-based line/column (including a token inside a nested list and the
;; trailing EOF). Returns 42 on success.
(import "../lex.tl")

(define (main) : i64
  (lex-span-self-test))