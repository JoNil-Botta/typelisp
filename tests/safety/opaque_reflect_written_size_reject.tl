;; A written `(type T)` operand names a foreign opaque aggregate, but its
;; layout stays unreachable (#8735).
(import opaque_dep)

(define (main) : i64
  (comptime (size-of (type opaque_dep.Connection))))