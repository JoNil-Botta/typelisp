;; Native Slice destinations do not expand foreach into arbitrary scatter.
(define (scatter-slice!
  [indexes : (& indexes (Slice i64))]
  [output : (&mut output (Slice i64))]
  [n : i64]) : unit
  (foreach ([i : i64 0 n]) (set! (array-ref output (array-ref indexes i)) i)))

(define (main) : i64
  42)