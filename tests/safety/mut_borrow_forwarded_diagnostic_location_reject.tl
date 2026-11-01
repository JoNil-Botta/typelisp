(define (probe [p : (& p i64)]) : unit
  (let
    [r : (&mut p i64) (&mut (deref p))]
    unit))

(define (main) : i64
  42)