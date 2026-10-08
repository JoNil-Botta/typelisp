;; A function of the defining module whose result holds the opaque type by
;; value is unusable outside the family (#6999).
(import opaque_dep)

(define (main) : i64
  (begin
    (opaque_dep.make 3)
    0))