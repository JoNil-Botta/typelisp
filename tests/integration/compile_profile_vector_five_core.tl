;; Deterministic five-distinct-identity side of the compact vector compile-cost
;; pair. Every identity has the same new/push/get demand as the one-identity
;; fixture, so profile and Cachegrind deltas attribute identity fan-out rather
;; than API-surface differences.
(import stdlib.vector)
(import (vector.vector i64 core) as vec_i64)
(import (vector.vector u64 core) as vec_u64)
(import (vector.vector i32 core) as vec_i32)
(import (vector.vector u32 core) as vec_u32)
(import (vector.vector bool core) as vec_bool)

(define (profile-vector-i64-ok?) : bool
  (let
    [values : vec_i64.Vec (vec_i64.new)]
    (begin
      (vec_i64.push (&mut values) 42)
      (= (vec_i64.get (& values) 0 0) 42))))

(define (profile-vector-u64-ok?) : bool
  (let
    [values : vec_u64.Vec (vec_u64.new)]
    (begin
      (vec_u64.push (&mut values) 42)
      (= (vec_u64.get (& values) 0 0) 42))))

(define (profile-vector-i32-ok?) : bool
  (let
    [values : vec_i32.Vec (vec_i32.new)]
    (begin
      (vec_i32.push (&mut values) 42)
      (= (vec_i32.get (& values) 0 0) 42))))

(define (profile-vector-u32-ok?) : bool
  (let
    [values : vec_u32.Vec (vec_u32.new)]
    (begin
      (vec_u32.push (&mut values) 42)
      (= (vec_u32.get (& values) 0 0) 42))))

(define (profile-vector-bool-ok?) : bool
  (let
    [values : vec_bool.Vec (vec_bool.new)]
    (begin
      (vec_bool.push (&mut values) true)
      (vec_bool.get (& values) 0 false))))

(define (main) : i64
  (if (and
    (profile-vector-i64-ok?)
    (profile-vector-u64-ok?)
    (profile-vector-i32-ok?)
    (profile-vector-u32-ok?)
    (profile-vector-bool-ok?))
    42
    0))