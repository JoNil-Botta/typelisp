;; #8776: a try error exit cannot carry a scratch-allocated payload out of a
;; with-scratch body.
(import stdlib.string)

(defenum Parsed
  (Ok i64)
  (Err String))

(define (parse [n : i64]) : Parsed
  (if (> n 0)
    (Parsed.Ok n)
    (Parsed.Err (string.int->string n))))

(define (checked [n : i64]) : Parsed
  (with-scratch (try (parse n)))
  (Parsed.Ok 0))

(define (main) : i64
  (match (checked -1234567)
    [(Parsed.Ok _) 9]
    [(Parsed.Err m)
      (if (string.eq (& m) "-1234567")
        100
        7)]))