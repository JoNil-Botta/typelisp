;; Repeated Decls expansions in a non-root module keep that module's view
;; current across splices (#8120): each expansion sees the functions earlier
;; ones generated, a generated name the root also declares resolves to the
;; module's definition inside the module, and a view whose signature names a
;; generated-import type stays correct.
(import stdlib.hashmap)
(import (hashmap.hashmap i64 i64) as counts)
(import decls_module_env_carry_dep as dep)

(define (shared-name [x : i64]) : i64
  (+ x 1000))

(define (main) : i64
  (let
    ;; step0 x = x + 1; step k adds k before calling step k - 1.
    [chain : i64 (dep.step4 0)]
    [through : i64 (dep.last 0)]
    [fresh : counts.Map (dep.fresh-counts)]
    (if (and
      (= chain 11)
      (= through 37)
      (= (dep.shared-name 0) 29)
      (= (shared-name 0) 1000)
      (= (counts.len (& fresh)) 0))
      42
      1)))