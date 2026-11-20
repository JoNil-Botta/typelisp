;; (init : T) cannot make an opaque value outside its module family (#6999).
(import opaque_dep)

(define (main) : i64
  (let
    ;; lint-allow: removed-init -- This test rejects init on an opaque type.
    [_c (init : opaque_dep.Connection)]
    0))