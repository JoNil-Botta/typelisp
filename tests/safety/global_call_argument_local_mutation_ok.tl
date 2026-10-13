(defstruct Big
  (a i64)
  (b i64)
  (c i64)
  (d i64))

(define g : Big
  (Big 1 2 3 4))

(define (use [r : (& r Big)] [n : i64]) : i64
  (+ r.a n))

(define (bump! [g : (&mut g Big)]) : i64
  (+= g.a 1)
  g.a)

(define (main) : i64
  (use
    (& g)
    (let
      [g : Big (Big 40 2 3 4)]
      (bump! (&mut g)))))