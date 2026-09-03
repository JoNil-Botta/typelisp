;; Locks down unsigned casts in both directions around bit 63. The scalar x86
;; instructions are signed, so each direction needs a distinct high-half path.
(define (u64-high) : u64
  (+ 9223372036854775807 (cast 1 : u64)))

(define (u64-max) : u64
  (cast -1 : u64))

;; Self-recursive, so no inliner admits it: without this barrier opt1's
;; tiny-leaf inlining plus constant folding evaluates every cast below at
;; compile time and deletes the runtime lowering this test locks down.
(define (opaque-u64 [value : u64] [rounds : i64]) : u64
  (if (> rounds 1)
    (+ value (opaque-u64 value (- rounds 1)))
    value))

(define (u64-to-f64 [x : u64]) : f64
  (cast (opaque-u64 x 1) : f64))

(define (u64-to-f32 [x : u64]) : f32
  (cast (opaque-u64 x 1) : f32))

(define (u8-to-f64 [x : u8]) : f64
  (cast (cast (opaque-u64 (cast x : u64) 1) : u8) : f64))

;; These self-recursive barriers keep opt1 from folding the reverse-direction
;; casts. Each source value is already representable in its declared precision.
(define (opaque-f64 [value : f64] [rounds : i64]) : f64
  (if (> rounds 1)
    (+ value (opaque-f64 value (- rounds 1)))
    value))

(define (opaque-f32 [value : f32] [rounds : i64]) : f32
  (if (> rounds 1)
    (+ value (opaque-f32 value (- rounds 1)))
    value))

(define (f64-to-u64 [x : f64]) : u64
  (cast (opaque-f64 x 1) : u64))

(define (f32-to-u64 [x : f32]) : u64
  (cast (opaque-f32 x 1) : u64))

(define (main) : i64
  (let
    [two63 : f64 9223372036854775808.0]
    [two63f : f32 9223372036854775808.0]
    (cond
      [(< (u64-to-f64 (u64-high)) two63) 1]
      [(< (u64-to-f64 (u64-max)) two63) 2]
      [(< (u64-to-f32 (u64-high)) two63f) 3]
      [(< (u64-to-f32 (u64-max)) two63f) 4]
      [(< (u8-to-f64 (cast 255 : u8)) 254.5) 5]
      [(> (u8-to-f64 (cast 255 : u8)) 255.5) 6]
      [(< (u64-to-f64 (cast 42 : u64)) 41.5) 7]
      [(> (u64-to-f64 (cast 42 : u64)) 42.5) 8]
      [(not
          (=
            (f64-to-u64 9223372036854774784.0)
            (- (u64-high) (cast 1024 : u64))))
        9]
      [(not (= (f64-to-u64 9223372036854775808.0) (u64-high))) 10]
      [(not
          (=
            (f64-to-u64 9223372036854777856.0)
            (+ (u64-high) (cast 2048 : u64))))
        11]
      [(not
          (=
            (f64-to-u64 18446744073709549568.0)
            (- (u64-max) (cast 2047 : u64))))
        12]
      [(not
          (=
            (f32-to-u64 9223371487098961920.0)
            (- (u64-high) (cast 549755813888 : u64))))
        13]
      [(not (= (f32-to-u64 9223372036854775808.0) (u64-high))) 14]
      [(not
          (=
            (f32-to-u64 9223373136366403584.0)
            (+ (u64-high) (cast 1099511627776 : u64))))
        15]
      [(not
          (=
            (f32-to-u64 18446742974197923840.0)
            (- (u64-max) (cast 1099511627775 : u64))))
        16]
      [else 0])))