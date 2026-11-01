;; Every generated function sees its predecessors in the same module; root
;; shadowing and a generated-import type retain their canonical meaning.
(import stdlib.hashmap)
(import (hashmap.hashmap i64 i64) as counts)
(import decls_module_env_carry_dep as dep)

(define (shared-name [x : i64]) : i64
  (+ x 1000))

(define (main) : i64
  (let
    [fresh : counts.Map (dep.fresh-counts)]
    (if (and
      (= (dep.step4 0) 11)
      (= (dep.last 0) 37)
      (= (dep.shared-name 0) 29)
      (= (shared-name 0) 1000)
      (= (dep.preserved-unsafe) 19)
      (= (counts.len (& fresh)) 0))
      42
      1)))