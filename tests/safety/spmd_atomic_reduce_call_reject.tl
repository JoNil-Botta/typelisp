;: Atomic side effects remain rejected in spmd-reduce value expressions.
(import "stdlib/atomic.tl")

(define (main [out : (Array i64)] [n : i64]) : i64
  (spmd-reduce sum ([i : i64 0 n]) 0 (atomic-i64-fetch-add! out i 1)))