(defstruct Big
  (a i64)
  (b i64)
  (c i64)
  (d i64))

(define g : Big
  (Big 1 2 3 4))

(define (rebind!) : unit
  (set! g (Big 9 9 9 9)))

(define (field-a [r : (& r Big)]) : (& r i64)
  (& r.a))

(define (read [r : (& r i64)] [_u : unit]) : i64
  (deref r))

(define (main) : i64
  (read (field-a (& g)) (rebind!)))