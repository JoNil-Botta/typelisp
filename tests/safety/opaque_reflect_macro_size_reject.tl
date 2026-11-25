;; A macro body's layout query runs as code of its module (#8735).
(import stdlib.comptime)
(import opaque_dep)

(defmacro (leak) : i64
  (comptime.expr-int (size-of (type opaque_dep.Connection))))

(define (main) : i64
  (leak))