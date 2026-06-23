;: SPEC SPMD contract: spmd-shuffle is valid only in SPMD scope.
(define (main) : i64
  (spmd-shuffle 1 0))