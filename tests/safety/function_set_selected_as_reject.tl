(import function_assignment_dep.cap as selected)

(define (big) : i64
  42)

(define (main) : i64
  (begin
    (set! selected big)
    42))