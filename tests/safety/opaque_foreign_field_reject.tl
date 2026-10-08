;; Reading a field of an opaque struct through a reference is rejected outside
;; its module family (#6999).
(import opaque_dep)

(define (peek [c : (& a opaque_dep.Connection)]) : i64
  c.fd)

(define (main) : i64
  0)