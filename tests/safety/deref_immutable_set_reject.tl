(define (write! [value : (& source i64)]) : unit
  (set! (deref value) 2))

(define (main) : i64
  0)