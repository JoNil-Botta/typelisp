;; A macro body cannot reach an opaque aggregate's fields through a type
;; derived from its operand (#8735).
(import stdlib.comptime)
(import opaque_dep)

(defmacro (fields [T : type]) : i64
  (comptime.expr-int (struct-field-count (reference-element-type T))))

(define (main) : i64
  (fields (& a opaque_dep.Connection)))