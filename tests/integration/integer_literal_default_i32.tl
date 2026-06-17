(define (unconstrained-default) : i32
  (let
    [x (+ 1 2)]
    x))

(define (contextual-i64) : i64
  (let
    [x : i64 1]
    x))

(define (main) : i64
  (if (and (= (unconstrained-default) 3) (= (contextual-i64) 1))
    42
    1))
