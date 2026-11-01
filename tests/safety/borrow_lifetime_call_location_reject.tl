(define (read [value : (&mut i64)]) : i64
  (deref value))

(define (main) : i64
  (let
    [state : i64 1]
    (read (&mut other state))))