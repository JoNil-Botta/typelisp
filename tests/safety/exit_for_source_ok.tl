;; A `for` over an array literal whose element exits never runs its loop: the
;; `for` ends at its source, as a `let` ends at a diverging initializer.
(define (sum-or-leave) : i64
  (let
    [s : i64 0]
    (for [x (array (ann 1 : i64) (return 42))]
      (set! s (+ s x)))
    s))

(define (main) : i64
  (sum-or-leave))