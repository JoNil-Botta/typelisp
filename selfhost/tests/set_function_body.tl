(define (bump x)
  (begin
    (set! x (+ x 1))
    x))

(bump 41)