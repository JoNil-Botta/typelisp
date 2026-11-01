(import stdlib.string)

(define (leak [n : i64]) : String
  (with-arena
    outer
    (let
      [text (string.int->string n)]
      (with-arena inner (return text))))
  "")

(define (main) : i64
  (string.string-length (leak -5)))