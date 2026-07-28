;: Atomic integer scatter keeps i32 and i64 buffer domains distinct.
(import stdlib.atomic)

(define (main [out : (& out atomic.AtomicI32Buffer)] [n : i64]) : unit
  (foreach ([i : i64 0 n]) (atomic.atomic-i64-add! out i 1)))