;; Copying one opaque value over another through raw pointers writes its
;; representation outside the family (#8734).
(import opaque_dep)

(define (copy
  [p : (MutPtr opaque_dep.Connection)]
  [q : (Ptr opaque_dep.Connection)]) : unit
  (unsafe
    (ptr-write! p (ptr-read q))))

(define (main) : i64
  0)