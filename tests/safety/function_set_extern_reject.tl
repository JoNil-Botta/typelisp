(extern (foreign) : i64)

(define (big) : i64
  42)

(define (main) : i64
  (begin
    (set! foreign big)
    42))