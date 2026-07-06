;; Module B for compile_profile_cross_file_single_compilation.tl - imports the
;; shared (vector i64) instantiation.
(module cross_single_b)

(import stdlib.vector)
(import (vector i64) as vec_b)

(define (count) : i64
  (let
    [v : vec_b.Vec (vec_b.new)]
    (vec_b.len (& v))))