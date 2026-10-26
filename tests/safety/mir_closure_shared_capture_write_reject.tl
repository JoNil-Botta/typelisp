;; A closure holding a shared reference keeps its loan while the closure is
;; still used: writing the referent between two calls is rejected.
(define (main) : i64
  (let
    [x : i64 1]
    [r : (& x i64) (& x)]
    [read : (-> i64)
      (lambda () : i64
        (deref r))]
    [first : i64 (read)]
    (begin
      (set! x 2)
      (+ first (read)))))