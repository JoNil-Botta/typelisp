(import stdlib.format)

(define (main) : i64
  (begin
    (format.format
      "{name}"
      (format.named name (cast 7 : i64))
      (format.named name (cast 8 : i64)))
    42))