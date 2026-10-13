(import stdlib.iterator)

(defstruct Big
  (a i64)
  (b i64)
  (c i64)
  (d i64))

(define g : Big
  (Big 1 2 3 4))

(define (rebind!) : unit
  (set! g (Big 9 9 9 9)))

(define (use [r : (& r Big)] [n : i64]) : i64
  (+ r.a n))

(define (main) : i64
  (use
    (& g)
    (begin
      (for [g (iterator.range 0 1)]
        (rebind!))
      42)))