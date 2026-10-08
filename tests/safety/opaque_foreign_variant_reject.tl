;; Constructing a variant of an opaque enum outside its module family is
;; rejected (#6999).
(import opaque_dep)

(define (main) : i64
  (let
    [_s (opaque_dep.Busy 3)]
    0))