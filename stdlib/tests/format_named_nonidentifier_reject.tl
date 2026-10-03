(import stdlib.format)

(define (main) : i64
  (format.format "{name}" (format.named "name" (cast 7 : i64)))
  42)