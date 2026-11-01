;; A mutable Slice reference does not own its elements either: a non-Copy
;; element taken by value is a move out of the mutable reference (#8449).
(define (first [s : (&mut s (Slice String))]) : (in s String)
  (array-ref s 0))

(define (main) : i64
  42)