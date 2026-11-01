;: A dispatcher call whose variant assigns `g`, while an earlier argument
;: still borrows `g`: the dispatcher is its own node (#7904).
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

(define (rebind-scalar [n : i64]) : i64
  (set! g (Big n n n n))
  n)

(defdispatch rebind (scalar rebind-scalar))

(define (main) : i64
  (read (field-a (& g)) (rebind 9)))