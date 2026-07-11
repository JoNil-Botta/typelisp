;; Module B for compile_profile_cross_file_single_compilation.tl - imports the
;; shared (vector i64) instantiation.
;; The short explicit identity is intentional: the entry imports this file by
;; a legacy module clause while checking cross-file specialization reuse.
(module cross_single_b)

(import stdlib.vector)
(import (vector i64) as vec_b)

(define (count) : i64
  (let
    [v : vec_b.Vec (vec_b.new)]
    (vec_b.len (& v))))