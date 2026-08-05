(define (write! [value : (& source (Tuple i64 i64))]) : unit
  (set! (tuple-ref value 0) 2))

(define (main) : i64
  0)