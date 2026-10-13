(module effects.deep)

(defstruct Big
  (a i64)
  (b i64)
  (c i64)
  (d i64))

(define g : Big
  (Big 1 2 3 4))

(define (reset!) : unit
  (set! g (Big 9 9 9 9)))

(define (read [r : (& r Big)]) : i64
  (effects.deep.reset!)
  r.a)

(define (main) : i64
  (read (& effects.deep.g)))