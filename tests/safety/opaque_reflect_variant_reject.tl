;; Variant reflection of a foreign opaque enum is rejected (#8735).
(import opaque_dep)

(define (main) : i64
  (comptime
    (enum-variant-count (reference-element-type (type (& a opaque_dep.State))))))