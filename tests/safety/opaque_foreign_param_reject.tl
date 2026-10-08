;; An opaque type cannot be a by-value parameter outside its module family
;; (#6999).
(import opaque_dep)

(define (take [_c : opaque_dep.Connection]) : i64
  0)

(define (main) : i64
  0)