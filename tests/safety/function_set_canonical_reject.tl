(import function_assignment_dep)

(define (main) : i64
  (begin
    (set! function_assignment_dep.cap function_assignment_dep.big)
    42))