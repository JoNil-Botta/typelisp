;; A composed derivation reaches the same gate (#8735).
(import opaque_dep)

(define (main) : i64
  (comptime
    (struct-field-count
      (reference-element-type
        (function-param-type (type (-> (& a opaque_dep.Connection) i64)) 0)))))