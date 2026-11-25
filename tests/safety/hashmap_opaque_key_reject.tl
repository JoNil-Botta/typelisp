;; A HashMap stores its keys by value, so an opaque type cannot key one outside
;; its module family; its sealed handle can (see owner_eq_hash_opaque).
(import stdlib.hashmap)
(import owner_eq_hash_dep as dep)
(import (hashmap.hashmap dep.Token i64) as token_map)

(define (main) : i64
  0)