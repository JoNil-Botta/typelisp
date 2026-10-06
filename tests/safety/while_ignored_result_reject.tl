(defenum Outcome
  (Ok i64)
  (Err i64))

(define (attempt) : Outcome
  (Outcome.Err 1))

(define (main) : i64
  (while false
    (attempt)
    unit)
  0)