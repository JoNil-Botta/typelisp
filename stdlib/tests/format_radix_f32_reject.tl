(import stdlib.format)

(define (main) : i64
  (format.format "{:x}" (cast 1.5 : f32))
  42)