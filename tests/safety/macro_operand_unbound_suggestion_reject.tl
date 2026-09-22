;; The operand is type-probed while `twice` captures it, and that probe's
;; unbound-name error is discarded without a suggestion scan. The expansion
;; then fails on the same name for real, and that reported diagnostic must keep
;; its near-miss suggestion and macro frame.
(defmacro (twice [e : Expr]) : Expr
  `(+ ,e ,e))

(define (main) : i64
  (let
    [alpha : i64 20]
    (twice alphq)))