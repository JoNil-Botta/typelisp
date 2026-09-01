(unsafe
  (define (danger [value : i64]) : i64
    value))

(define (main) : i64
  (let
    [leaked : (-> i64 i64)
      (unsafe
        danger)]
    (leaked 42)))