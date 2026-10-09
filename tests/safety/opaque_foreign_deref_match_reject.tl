;; Matching a dereferenced opaque value needs no pattern gate when its arm is a
;; wildcard; the dereference itself is rejected (#8734).
(import opaque_dep)

(define (load [r : (& a opaque_dep.State)]) : i64
  (match (deref r)
    [_ 0]))

(define (main) : i64
  0)