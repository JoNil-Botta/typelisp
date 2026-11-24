;; Reflection cannot reach an opaque aggregate's fields through a type derived
;; from an allowed one (#8735).
(import opaque_dep)

(define (main) : i64
  (comptime
    (struct-field-count
      (reference-element-type (type (& a opaque_dep.Connection))))))