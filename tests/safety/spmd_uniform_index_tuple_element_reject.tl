(define (fill
  [xs : (& xs (Slice i64))]
  [pairs : (&mut pairs (Slice (Tuple i64 i64)))]
  [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (set! (tuple-ref (array-ref pairs 0) 1) (array-ref xs i))))