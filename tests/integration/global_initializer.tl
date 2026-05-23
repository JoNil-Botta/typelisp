; refs #189: a global initialized by a function call is computed before main.
(define (factorial [n : i64]) : i64
  (if (= n 0)
      1
      (* n (factorial (- n 1)))))

(define result (factorial 5))

(define (main) : i64
  result)
