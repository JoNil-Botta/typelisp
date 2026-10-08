;; Borrowing a field of an opaque struct is rejected outside its module family
;; (#6999).
(import opaque_dep)

(define (peek [c : (& a opaque_dep.Connection)]) : i64
  (deref (& c.fd)))

(define (main) : i64
  0)