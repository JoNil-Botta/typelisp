;; unsafe does not open an opaque representation: a raw read of a field is
;; rejected outside the module family (#6999).
(import opaque_dep)

(define (peek [p : (Ptr opaque_dep.Connection)]) : i64
  (unsafe
    (deref p).fd))

(define (main) : i64
  0)