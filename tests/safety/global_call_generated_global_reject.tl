(defstruct Big
  (a i64)
  (b i64)
  (c i64)
  (d i64))

(defmacro (global-module) : Module
  `(begin
    (module generated.global_call)
    (define g : Big
      (Big 1 2 3 4))
    (define (reset!) : unit
      (set! g (Big 9 9 9 9)))
    (define (observe [value : (& r Big)]) : i64
      (reset!)
      value.a)))

(import (global-module) as generated)

(define (main) : i64
  (generated.observe (& generated.g)))