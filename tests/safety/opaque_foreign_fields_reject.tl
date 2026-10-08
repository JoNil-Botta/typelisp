;; A by-name struct pattern reads an opaque struct's fields, so it is rejected
;; outside the struct's module family like a positional one (#6999).
(import opaque_dep)

(define (peek [c : (& a opaque_dep.Connection)]) : i64
  (match (deref c)
    [(fields fd) fd]))

(define (main) : i64
  0)