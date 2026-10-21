;; Two consuming modules expand one canonical identity into the same explicit
;; target. The target segment is shared, so its incompatible payload diagnoses.
(import stdlib.comptime)

(defmacro (emit [value : comptime.Expr]) : Decls
  (match value
    [(comptime.Expr.Int _)
      `(module
        generated.decls_explicit_target
        (define answer : i64
          1))]
    [_
      `(module
        generated.decls_explicit_target
        (define answer : i64
          2))]))

(defmacro (make-one) : Module
  `(begin
    (module generated.decls_explicit_target_one)
    (emit 3)))

(defmacro (make-two) : Module
  `(begin
    (module generated.decls_explicit_target_two)
    (emit (+ 1 2))))

(import (make-one) as one)
(import (make-two) as two)

(define (main) : i64
  42)