;; `eq.gen` runs only in the nominal type's exact canonical owner module.
(import stdlib.eq)
(import owner_eq_hash_dep as dep)

(eq.gen dep.Point)

(define (main) : i64
  0)