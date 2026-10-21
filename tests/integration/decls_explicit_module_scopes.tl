(import stdlib.comptime)

(defmacro (emit-global) : Decls
  `(begin
    (module generated.decls_shared_global)
    (define shared-value : i64
      14)))

(defmacro (emit-mixed) : Decls
  `(begin
    (define local-value : i64
      14)
    (module generated.decls_shared_mixed)
    (define shared-value : i64
      14)))

(defmacro (make-global [name : comptime.Expr]) : Module
  `(begin
    (module ,name)
    (define anchor : i64
      0)
    (emit-global)))

(defmacro (make-mixed [name : comptime.Expr]) : Module
  `(begin
    (module ,name)
    (emit-mixed)))

(import (make-global generated.decls_global_one) as global-one)
(import (make-global generated.decls_global_two) as global-two)
(import (make-mixed generated.decls_mixed_one) as mixed-one)
(import (make-mixed generated.decls_mixed_two) as mixed-two)
(import (make-mixed generated.decls_mixed_one) as repeated)

(define (main) : i64
  (+
    global-one.anchor
    global-two.anchor
    mixed-one.local-value
    mixed-two.local-value
    repeated.local-value))