(define (fill [out : (&mut out (Slice bool))] [n : i64]) : unit
  (foreach ([i : i64 0 n]) (set! (array-ref out 0) (< i 3))))