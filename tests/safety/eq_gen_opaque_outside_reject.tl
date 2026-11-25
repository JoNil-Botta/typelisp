;; Outside its module family an opaque type cannot get generated structural
;; equality.
(import stdlib.eq)
(import owner_eq_hash_dep as dep)

(eq.gen dep.Token)

(define (main) : i64
  0)