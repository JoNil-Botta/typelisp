;: A `with` cleanup named by a local function value (here `rebind!`) is any
;: function value, not the module function `release` it shadows (#7904).
(defstruct Big
  (a i64)
  (b i64)
  (c i64)
  (d i64))

(define g : Big
  (Big 1 2 3 4))

(define (field-a [r : (& r Big)]) : (& r i64)
  (& r.a))

(define (read [r : (& r i64)] [n : i64]) : i64
  (+ n (deref r)))

(define (rebind! [n : i64]) : unit
  (set! g (Big n n n n)))

(define (release [n : i64]) : unit
  unit)

(define (main) : i64
  (read
    (field-a (& g))
    (let
      [release : (-> i64 unit) rebind!]
      (with ([v 1 release]) 0))))