(import stdlib.string)

(define (leak [n : i64]) : String
  (let
    [length : i64 (with-arena phase (return (string.int->string n)))]
    "unreachable"))

(define (main) : i64
  (string.string-length (leak -5)))