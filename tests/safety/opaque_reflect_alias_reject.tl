;; An array of an opaque aggregate named through an import alias reaches the
;; same gate in a macro body (#8735).
(import stdlib.comptime)
(import opaque_dep as od)

(defmacro (leak) : i64
  (comptime.expr-int (size-of (type (Array od.Connection 2)))))

(define (main) : i64
  (leak))