;; #9924: Float `neg` constant folding and comptime evaluation must flip the
;; IEEE-754 sign bit at the bit level, preserving -0.0 for f32 and f64.
(import stdlib.io)

(define (is-neg-zero-f64 [x : f64]) : bool
  (and
    (= x 0.0)
    (< (/ 1.0 x) 0.0)
    (= (io.float-f64-bits x) (shl (cast 1 : u64) 63))))

(define (is-pos-zero-f64 [x : f64]) : bool
  (and (= x 0.0) (> (/ 1.0 x) 0.0) (= (io.float-f64-bits x) (cast 0 : u64))))

(define (is-neg-zero-f32 [x : f32]) : bool
  (and
    (= x (cast 0.0 : f32))
    (< (/ (cast 1.0 : f32) x) (cast 0.0 : f32))
    (= (io.float-f32-bits x) (cast 0x80000000 : u32))))

(define (is-pos-zero-f32 [x : f32]) : bool
  (and
    (= x (cast 0.0 : f32))
    (> (/ (cast 1.0 : f32) x) (cast 0.0 : f32))
    (= (io.float-f32-bits x) (cast 0 : u32))))

(define (case-const-fold) : bool
  (let
    [nz64 : f64 (neg 0.0)]
    [pz64 : f64 (neg -0.0)]
    [nz64-dbl : f64 (neg (neg 0.0))]
    [nz32 : f32 (neg (cast 0.0 : f32))]
    [pz32 : f32 (neg (cast -0.0 : f32))]
    [nz32-dbl : f32 (neg (neg (cast 0.0 : f32)))]
    [n15-64 : f64 (neg 1.5)]
    [p15-64 : f64 (neg -1.5)]
    [n15-32 : f32 (neg (cast 1.5 : f32))]
    [p15-32 : f32 (neg (cast -1.5 : f32))]
    (and
      (is-neg-zero-f64 nz64)
      (is-pos-zero-f64 pz64)
      (is-pos-zero-f64 nz64-dbl)
      (is-neg-zero-f32 nz32)
      (is-pos-zero-f32 pz32)
      (is-pos-zero-f32 nz32-dbl)
      (= n15-64 -1.5)
      (= p15-64 1.5)
      (= n15-32 (cast -1.5 : f32))
      (= p15-32 (cast 1.5 : f32)))))

(define (case-comptime) : bool
  (let
    [ct-nz64 : f64 (comptime (neg 0.0))]
    [ct-pz64 : f64 (comptime (neg -0.0))]
    [ct-dbl64 : f64 (comptime (neg (neg 0.0)))]
    [ct-nz32 : f32 (comptime (neg (cast 0.0 : f32)))]
    [ct-pz32 : f32 (comptime (neg (cast -0.0 : f32)))]
    [ct-dbl32 : f32 (comptime (neg (neg (cast 0.0 : f32))))]
    [ct-n15-64 : f64 (comptime (neg 1.5))]
    [ct-n15-32 : f32 (comptime (neg (cast 1.5 : f32)))]
    (and
      (is-neg-zero-f64 ct-nz64)
      (is-pos-zero-f64 ct-pz64)
      (is-pos-zero-f64 ct-dbl64)
      (is-neg-zero-f32 ct-nz32)
      (is-pos-zero-f32 ct-pz32)
      (is-pos-zero-f32 ct-dbl32)
      (= ct-n15-64 -1.5)
      (= ct-n15-32 (cast -1.5 : f32)))))

(define (main) : i64
  (unless (case-const-fold) (return 1))
  (unless (case-comptime) (return 2))
  42)