(define (main) : i64
  (let
    [out : (__tl_dyn-array i64) (__tl_make-array i64 4)]
    (spmd-compact
      ([i : i64 0 3] [slot : i64 0])
      true
      (set! (array-ref out i) slot))))