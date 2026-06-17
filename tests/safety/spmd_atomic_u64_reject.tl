;: Atomic integer scatter is intentionally limited to i32 and i64 arrays.
(import "stdlib/atomic.tl")

(define (main [out : (Array u64)] [n : i64]) : unit
  (foreach ([i : i64 0 n]) (atomic-i64-add! out i 1)))