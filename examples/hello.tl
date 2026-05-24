;; hello.tl — A simple TypeLisp program
(define (factorial [n : i64]) : i64
  (if (= n 0)
    1
    (* n (factorial (- n 1)))))

(define result
  (factorial 5))