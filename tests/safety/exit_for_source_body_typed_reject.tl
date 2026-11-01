;; The body of a `for` whose source exits never runs, but it is still typed.
(define (sum-or-leave) : i64
  (let
    [s : i64 0]
    (for [x (array 1 (return 42))]
      (set! s "text"))
    s))

(define (main) : i64
  (sum-or-leave))