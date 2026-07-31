;; Module A for compile_profile_cross_file_single_compilation.tl - imports the
;; shared (vector i64) instantiation.
;; The short explicit identity is intentional: the entry imports this sibling
;; by canonical dotted identity while checking cross-file specialization reuse.
(module cross_single_a)

(import stdlib.vector)
(import (vector.vector i64) as vec_a)

(define (count) : i64
  (let
    [v : vec_a.Vec (vec_a.new)]
    (vec_a.len (& v))))