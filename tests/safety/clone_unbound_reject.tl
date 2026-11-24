;; #8232/#7073: `clone` is no longer a compiler-special form; calling it
;; without a binding in scope fails as an ordinary unbound name.
(define (main) : i64
  (clone 42))