;; An opaque type cannot be embedded by value in another struct outside its
;; module family (#6999).
(import opaque_dep)

(defstruct Wrapper
  (inner opaque_dep.Connection))

(define (main) : i64
  0)