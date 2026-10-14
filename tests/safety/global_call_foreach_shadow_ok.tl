(defstruct Big
  (a i64)
  (b i64)
  (c i64)
  (d i64))

(define g : Big
  (Big 1 2 3 4))

(define (local-loop) : unit
  (foreach ([g : i64 0 2]) (set! g (+ g 1))))

(define (read-after [r : (& r Big)]) : i64
  (begin
    (local-loop)
    r.a))

(define (main) : i64
  (read-after (& g)))