;; A dereference that stays a place is not a by-value read: reborrowing an
;; opaque referent outside its family is allowed (#8734).
(import opaque_dep)

(define (reborrow [c : (& a opaque_dep.Connection)]) : i64
  (opaque_dep.connection-fd (& (deref c))))

(define (main) : i64
  (opaque_dep.with-connection 42 reborrow))