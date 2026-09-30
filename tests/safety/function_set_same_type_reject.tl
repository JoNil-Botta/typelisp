(define (cap) : i64
  4096)

(define (big) : i64
  42)

(define (main) : i64
  (begin
    (set! cap big)
    42))