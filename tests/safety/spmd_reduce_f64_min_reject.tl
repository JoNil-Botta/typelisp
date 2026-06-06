;: SPEC SPMD contract: min/max reductions support integer lanes only.
(define (main [xs : (Array f64)] [n : i64] [seed : f64]) : f64
  (spmd-reduce min ([i : i64 0 n]) seed (array-ref xs i)))