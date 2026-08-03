;; Slice has no by-value layout; it is legal only behind Ref/MutRef.
(define (bad [s : (Slice i64)]) : i64
  0)