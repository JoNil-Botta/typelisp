;; Caller-owned references remain valid when a scalar storage owner has the same name.
(define (keep [a : i64] [p : (& a i64)]) : i64
  (let
    [r (& a a)]
    (+ a (deref r))))

(define (main) : i64
  0)