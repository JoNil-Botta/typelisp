(defstruct Big
  (a i64)
  (b i64)
  (c i64)
  (d i64))

(define g : Big
  (Big 1 2 3 4))

(define (change-copy! [g : Big]) : unit
  (set! g.a 9))

(define (rebind!) : unit
  (let
    [g (Big 5 6 7 8)]
    (set! g.a 9)
    (change-copy! g)))

(define (read-after [r : (& r Big)]) : i64
  (begin
    (rebind!)
    r.a))

(define (main) : i64
  (read-after (& g)))