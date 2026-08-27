;: Lane identity forms are not valid in spmd-scan bodies.
; Compatibility exception for #3772: direct spmd-scan body writes still use bare
; array-set! so the checker sees the compiler array-write AST.

(define (bad [out : (__tl_dyn-array i64)] [n : i64]) : unit
  (spmd-scan
    sum
    ([i : i64 0 n] [prefix : i64 0])
    i
    (set! (array-ref out i) (program-index))))