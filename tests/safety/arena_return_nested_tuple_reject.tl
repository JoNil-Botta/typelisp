(import stdlib.string)

(define (leak [n : i64]) : (Tuple String i64)
  (with-arena
    phase
    (let
      [value (tuple (string.int->string n) n)]
      (return value)))
  (tuple "" 0))

(define (main) : i64
  (let
    [value (leak -5)]
    (string.string-length (tuple-ref value 0))))