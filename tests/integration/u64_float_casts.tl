;; Locks down unsigned u64 -> float casts for values with the high bit set.
;; The signed cvtsi2s{s,d}q path turns these into negative floats; a correct
;; unsigned lowering keeps them at or above 2^63.
(define (u64-high) : u64
  (+ (cast 9223372036854775807 : u64) (cast 1 : u64)))

(define (u64-max) : u64
  (cast -1 : u64))

(define (u64-to-f64 [x : u64]) : f64
  (cast x : f64))

(define (u64-to-f32 [x : u64]) : f32
  (cast x : f32))

(define (u8-to-f64 [x : u8]) : f64
  (cast x : f64))

(define (main) : i64
  (let
    [two63 : f64 9223372036854775808.0]
    [two63f : f32 9223372036854775808.0]
    (cond
      (< (u64-to-f64 (u64-high)) two63)
      1
      (< (u64-to-f64 (u64-max)) two63)
      2
      (< (u64-to-f32 (u64-high)) two63f)
      3
      (< (u64-to-f32 (u64-max)) two63f)
      4
      (< (u8-to-f64 (cast 255 : u8)) 254.5)
      5
      (> (u8-to-f64 (cast 255 : u8)) 255.5)
      6
      (< (u64-to-f64 (cast 42 : u64)) 41.5)
      7
      (> (u64-to-f64 (cast 42 : u64)) 42.5)
      8
      0)))