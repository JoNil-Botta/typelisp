;; A value read through a raw pointer cannot be held by value outside the
;; family (#6999): the read itself is rejected, before the `let` binds it
;; (#8734).
(import opaque_dep)

(define (peek [p : (Ptr opaque_dep.Connection)]) : i64
  (unsafe
    (let
      [c (ptr-read p)]
      (opaque_dep.connection-fd (& c)))))

(define (main) : i64
  0)