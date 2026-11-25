;; Layout queries cannot reach an opaque aggregate through a derived type
;; (#8735).
(import opaque_dep)

(define (main) : i64
  (comptime
    (size-of (reference-element-type (type (& a opaque_dep.Connection))))))