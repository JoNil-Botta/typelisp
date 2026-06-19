(define (unconstrained-default) : i32
  (let
    [x (+ 1 2)]
    x))

(define (contextual-i64) : i64
  (let
    [x : i64 1]
    x))

(define (explicit-wide-cast) : i64
  (cast (cast 0x100000000 : u64) : i64))

(define (main) : i64
  (if (and
    (= (unconstrained-default) 3)
    (= (contextual-i64) 1)
    (= (explicit-wide-cast) 4294967296))
    42
    1))