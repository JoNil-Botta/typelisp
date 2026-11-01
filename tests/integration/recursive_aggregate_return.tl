(defstruct Big
  (a i64)
  (b i64)
  (c i64))

(define (make [depth : i64]) : Big
  (if (> depth 0)
    (make (- depth 1))
    (Big 10 11 21)))

(define (main) : i64
  (let
    [value : Big (make 2)]
    (+ value.a value.b value.c)))