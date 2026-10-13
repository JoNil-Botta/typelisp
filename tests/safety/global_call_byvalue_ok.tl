(defstruct Big
  (a i64)
  (b i64)
  (c i64)
  (d i64))

(define g : Big
  (Big 1 2 3 4))

(define (rebind!) : unit
  (set! g (Big 9 9 9 9)))

(define (read-after [r : Big]) : i64
  (begin
    (rebind!)
    r.a))

(define (main) : i64
  (read-after g))