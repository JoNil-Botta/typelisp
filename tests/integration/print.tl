(import stdlib.io)

(define (main) : i64
  (begin
    (io.println "{}" (cast 42 : i64))
    (io.println "{}" false)
    0))