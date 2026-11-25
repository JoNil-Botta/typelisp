;; Outside its module family an opaque type cannot get a generated structural
;; hash.
(import stdlib.hash)
(import owner_eq_hash_dep as dep)

(hash.gen dep.Token)

(define (main) : i64
  0)