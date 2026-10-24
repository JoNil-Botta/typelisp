;; The generated module's repeated carries cannot drop an unsafe marker.
(defmacro (emit-step [name : Expr]) : Decls
  `(define (,name) : i64
    7))

(defmacro (provider) : Module
  `(begin
    (module carried-unsafe)
    (unsafe
      (define (hidden) : i64
        19))
    (emit-step first)
    (emit-step second)
    (define (bad) : i64
      (hidden))))

(import (provider) as carried)

(define (main) : i64
  (carried.bad))