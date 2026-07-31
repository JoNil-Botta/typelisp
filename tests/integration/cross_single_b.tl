;; Module B for compile_profile_cross_file_single_compilation.tl - imports the
;; shared (vector i64) instantiation.
;; The short explicit identity is intentional: the entry imports this sibling
;; by canonical dotted identity while checking cross-file specialization reuse.
(module cross_single_b)

(import stdlib.vector)
(import (vector.vector i64) as vec_b)

(define (count) : i64
  (let
    [v : vec_b.Vec (vec_b.new)]
    (vec_b.len (& v))))