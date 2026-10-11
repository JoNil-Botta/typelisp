(defstruct Big
  (a i64)
  (b i64)
  (c i64)
  (d i64))

(define g : Big
  (Big 1 2 3 4))

(define (rebind!) : unit
  (set! g (Big 9 9 9 9)))

(define (a! [n : i64]) : unit
  (if (> n 0)
    (b! (- n 1))
    (rebind!)))

(define (b! [n : i64]) : unit
  (a! n))

(define (read-after [r : (& r Big)]) : i64
  (begin
    (b! 2)
    r.a))

(define (main) : i64
  (read-after (& g)))