;; Returning a captured reference retains the same code-address exclusion.
(define (main) : i64
  (let
    [x : i64 42]
    [rx : (& x i64) (& x)]
    [f
      (lambda () : (& x i64)
        rx)]
    [g
      (lambda () : (& x i64)
        rx)]
    (if (and (= (deref (f)) 42) (= (deref (g)) 42))
      42
      1)))