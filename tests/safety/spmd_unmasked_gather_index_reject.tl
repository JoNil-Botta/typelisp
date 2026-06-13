;: SPEC SPMD contract: unmasked foreach reads reject gather-like indexes.
(define (main
  [xs : (Array i64)]
  [ix : (Array i64)]
  [out : (Array i64)]
  [n : i64]) : unit
  (foreach ([i : i64 0 n]) (array-set! out i (array-ref xs (array-ref ix i)))))