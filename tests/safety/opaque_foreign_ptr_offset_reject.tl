;; Pointer arithmetic scales by the pointee's size, which is part of the
;; opaque representation (#8734).
(import opaque_dep)

(define (next [p : (Ptr opaque_dep.Connection)]) : (Ptr opaque_dep.Connection)
  (unsafe
    (ptr-offset p 1)))

(define (main) : i64
  0)