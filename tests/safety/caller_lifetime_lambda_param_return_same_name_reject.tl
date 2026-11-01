;; A lambda's parameter spelled like the enclosing caller lifetime owns its
;; storage; the lambda's types name the caller's lifetime.
(define (leak [p : (& a i64)]) : (& a i64)
  (let
    [g
      ; Must fail: `(& a)` borrows the lambda's parameter.
      (lambda ([a : i64] [q : (& a i64)]) : (& a i64)
        (let
          [r (& a)]
          r))]
    (g 1 p)))

(define (main) : i64
  0)