;: Atomic helpers are sequentially consistent only and expose no ordering arg.
(import "stdlib/atomic.tl")

(define (main [out : (Array i64)] [n : i64]) : unit
  (foreach ([i : i64 0 n]) (atomic-i64-add! out i 1 0)))