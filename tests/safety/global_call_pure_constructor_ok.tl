(defstruct Big
  (a i64)
  (b i64)
  (c i64)
  (d i64))

(define g : Big
  (Big 1 2 3 4))

(define (rebind!) : unit
  (set! g (Big 9 9 9 9)))

(define (read-after [r : (& r Big)]) : i64
  (begin
    (Big 5 6 7 8)
    r.a))

(define (main) : i64
  (let
    [writer rebind!]
    (read-after (& g))))