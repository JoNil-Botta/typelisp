(import stdlib.string)

(defenum Parsed
  (Ok i64)
  (Err String))

(define (parse [n : i64]) : Parsed
  (if (> n 0)
    (Parsed.Ok n)
    (Parsed.Err (string.int->string n))))

(define (leak [n : i64]) : Parsed
  (let
    [value : i64 (with-arena phase (try (parse n)))]
    (Parsed.Ok value)))

(define (main) : i64
  (match (leak -12345)
    [(Parsed.Ok value) value]
    [(Parsed.Err message) (string.string-length message)]))