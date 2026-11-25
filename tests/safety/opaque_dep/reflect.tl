(module opaque_dep.reflect)

(import opaque_dep)

;; Inside the module family every layout and reflection query works (#8735).
(define (connection-facts) : i64
  (+
    (comptime (size-of (type opaque_dep.Connection)))
    (comptime (struct-field-count (type opaque_dep.Connection)))
    (comptime
      (enum-variant-count
        (reference-element-type (type (& a opaque_dep.State)))))
    (comptime (offset-of (type opaque_dep.Connection) fd))))