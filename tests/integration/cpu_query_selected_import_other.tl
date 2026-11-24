(define (f [index : i64]) : i64
  (+ index 17))

(define (g [leaf : i64] [subleaf : i64]) : i64
  (+ (+ leaf subleaf) 25))

(define (h [leaf : i64] [subleaf : i64]) : (Tuple i32 i32 i32 i32)
  (tuple
    (cast (+ leaf 1) : i32)
    (cast (+ subleaf 2) : i32)
    (cast 3 : i32)
    (cast 4 : i32)))