;; A repeated splice still switches to its explicit module. Both following
;; declarations therefore share that owner and must diagnose their duplicate.
(defmacro (emit-global) : Decls
  `(begin
    (module generated.decls_explicit_global)
    (define global-value : i64
      14)))

(defmacro (make-one) : Module
  `(begin
    (module generated.decls_explicit_one)
    (emit-global)
    (define value : i64
      14)))

(defmacro (make-two) : Module
  `(begin
    (module generated.decls_explicit_two)
    (emit-global)
    (define value : i64
      14)))

(import (make-one) as one)
(import (make-two) as two)

(define (main) : i64
  42)