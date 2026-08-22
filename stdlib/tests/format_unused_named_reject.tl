(import stdlib.format)

(define (main) : i64
  (begin
    (format.format
      "{used}"
      (format.named used (cast 7 : i64))
      (format.named unused (cast 8 : i64)))
    42))