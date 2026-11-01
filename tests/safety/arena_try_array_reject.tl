(import stdlib.string)

(defenum Parsed
  (Ok i64)
  (Err (Array String 1)))

(define (parse [n : i64]) : Parsed
  (Parsed.Err (array (string.int->string n))))

(define (leak [n : i64]) : Parsed
  (let
    [value : i64 (with-arena phase (try (parse n)))]
    (Parsed.Ok value)))

(define (main) : i64
  (match (leak -12345)
    [(Parsed.Ok n) n]
    [(Parsed.Err items) (string.string-length (array-ref items 0))]))