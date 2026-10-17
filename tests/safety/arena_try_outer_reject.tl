(import stdlib.string)

(defenum Parsed
  (Ok i64)
  (Err String))

(define (parse [n : i64]) : Parsed
  (Parsed.Err (string.int->string n)))

(define (leak [n : i64]) : Parsed
  (with-arena
    outer
    (let
      [result (parse n)]
      (with-arena inner (try result))))
  (Parsed.Ok 0))

(define (main) : i64
  (match (leak -12345)
    [(Parsed.Ok value) value]
    [(Parsed.Err message) (string.string-length message)]))