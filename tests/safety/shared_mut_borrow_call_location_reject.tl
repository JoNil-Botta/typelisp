(define (write [value : (&mut i64)]) : unit
  (set! (deref value) 1))

(define (main) : unit
  (let
    [state : i64 1]
    [shared : (& state i64) (& state)]
    (write (&mut shared))))