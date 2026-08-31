(define (write-at!
  [out : (&mut out (__tl_dyn-array i64))]
  [index : i64]
  [value : i64]) : unit
  (set! (array-ref out index) value))

(define (main) : i64
  (let
    [out : (__tl_dyn-array i64) (__tl_make-array i64 4)]
    (spmd-compact
      ([i : i64 0 3] [slot : i64 0])
      true
      (write-at! (&mut out) i slot))))