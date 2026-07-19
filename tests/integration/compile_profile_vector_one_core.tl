;; Deterministic one-identity side of the compact vector compile-cost pair.
;; Keep the per-identity demand in sync with compile_profile_vector_five_core.tl.
(import stdlib.vector)
(import (vector.vector i64 core) as vec_i64)

(define (profile-vector-i64-ok?) : bool
  (let
    [values : vec_i64.Vec (vec_i64.new)]
    (begin
      (vec_i64.push (&mut values) 42)
      (= (vec_i64.get (& values) 0 0) 42))))

(define (main) : i64
  (if (profile-vector-i64-ok?)
    42
    0))