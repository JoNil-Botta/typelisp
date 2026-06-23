;: SPEC SPMD contract: first shuffle slice supports numeric scalar lanes only.
(define (main [xs : (Array bool)] [out : (Array bool)] [n : i64]) : unit
  (foreach ([i : i64 0 n]) (array-set! out i (spmd-shuffle (array-ref xs i) 0))))