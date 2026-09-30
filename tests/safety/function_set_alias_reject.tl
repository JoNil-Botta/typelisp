(import function_assignment_dep as dep)

(define (main) : i64
  (begin
    (set! dep.cap dep.big)
    42))