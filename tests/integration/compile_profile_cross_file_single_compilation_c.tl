;; Module C for compile_profile_cross_file_single_compilation.tl - imports the
;; shared (vector i64) instantiation.
(module cross_single_c)

(import stdlib.vector)
(import (vector i64) as vec_c)

(define (count) : i64
  (let
    [v : vec_c.Vec (vec_c.new)]
    (vec_c.len (& v))))