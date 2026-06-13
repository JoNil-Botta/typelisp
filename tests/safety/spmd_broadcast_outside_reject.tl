;: SPEC SPMD contract: spmd-broadcast is valid only in SPMD scope.
(define (main) : i64
  (spmd-broadcast 1 0))