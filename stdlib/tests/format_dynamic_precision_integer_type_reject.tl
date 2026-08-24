(import stdlib.format)

(define (main) : i64
  (begin
    (format.format "{0:.1$}" (cast 7 : i64) (cast 3 : u64))
    42))