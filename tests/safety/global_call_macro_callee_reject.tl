;: Two calls a macro template forms at one position: the call made while `g`
;: is borrowed is the one reported (#7904).
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

(defmacro (invoke [f : Expr]) : Expr
  `(,f))

(define (first!) : unit
  (set! g (Big 1 1 1 1)))

(define (second!) : unit
  (set! g (Big 2 2 2 2)))

(define (main) : i64
  (invoke first!)
  (read
    (field-a (& g))
    (begin
      (invoke second!)
      0)))