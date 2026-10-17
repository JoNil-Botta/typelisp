;: A `with` cleanup receives its still-borrowed value, `(& g)`, and assigns
;: `g`: as for the call `(reset-then-read (& g))` (#7904). Main accepted it.
(defstruct Big
  (a i64)
  (b i64)
  (c i64)
  (d i64))

(define g : Big
  (Big 1 2 3 4))

(define (reset-then-read [r : (& g Big)]) : unit
  (set! g (Big 0 0 0 0))
  (if (= r.a 0)
    unit
    unit))

(define (main) : i64
  (with ([v (& g) reset-then-read]) 0))