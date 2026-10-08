;; Constructing an opaque struct outside its module family is rejected (#6999).
(import opaque_dep.Connection)

(define (main) : i64
  (let
    [_c (Connection 3)]
    0))