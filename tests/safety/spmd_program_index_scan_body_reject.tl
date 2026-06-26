;: Lane identity forms are not valid in spmd-scan bodies.
; Compatibility exception for #3772: direct spmd-scan body writes still use bare
; array-set! so the checker sees the compiler array-write AST.
(import stdlib.array)

(define (bad [out : (Array i64)] [n : i64]) : unit
  (spmd-scan
    sum
    ([i : i64 0 n] [prefix : i64 0])
    i
    (array-set! out i (program-index))))