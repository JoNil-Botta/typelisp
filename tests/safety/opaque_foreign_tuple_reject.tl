;; A tuple element holds its type by value, even behind a reference to the
;; tuple (#6999).
(import opaque_dep)

(define (take [_t : (& a (Tuple opaque_dep.Connection i64))]) : i64
  0)

(define (main) : i64
  0)