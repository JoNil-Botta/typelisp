(defstruct Big
  (a i64)
  (b i64)
  (c i64)
  (d i64))

(define g : Big
  (Big 1 2 3 4))

(define (rebind!) : unit
  (set! g (Big 9 9 9 9)))

(define (cleanup [value : i64]) : unit
  (rebind!))

(define (read-after [r : (& r Big)]) : i64
  (begin
    (with ([value 1 cleanup]) unit)
    r.a))

(define (main) : i64
  (read-after (& g)))