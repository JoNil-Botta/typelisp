;; `offset-of` is a layout query too (#8735).
(import opaque_dep)

(define (main) : i64
  (comptime
    (offset-of (reference-element-type (type (& a opaque_dep.Connection))) fd)))