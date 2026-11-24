;; Naming queries reveal nothing about the representation and stay allowed
;; outside the module family (#8735).
(import opaque_dep)

(define (main) : i64
  (+
    (comptime (string-length (type-nominal-name (type opaque_dep.Connection))))
    (comptime (string-length (type-kind (type opaque_dep.Connection))))
    (comptime (string-length (type-nominal-module (type opaque_dep.State))))
    (if (> (comptime (string-length (type-key (type opaque_dep.Connection)))) 0)
      16
      0)))