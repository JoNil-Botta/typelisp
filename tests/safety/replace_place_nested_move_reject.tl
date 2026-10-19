(define (probe [p : (& p (Box String))]) : unit
  (let
    [_old (deref (deref p))]
    unit))

(define (main) : i64
  42)