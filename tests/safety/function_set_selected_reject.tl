(import function_assignment_dep.cap)

(define (big) : i64
  42)

(define (main) : i64
  (begin
    (set! cap big)
    42))