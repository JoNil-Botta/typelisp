;; Locks down unsigned casts in both directions around bit 63. The scalar x86
;; instructions are signed, so each direction needs a distinct high-half path.
(import stdlib.math)

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

;; Compare the production runtime path with both its exact IEEE payload and a
;; foldable constant-cast equivalent. At opt1/2 the latter is eligible for
;; constant evaluation while `opaque-u64` keeps the former in runtime code.
(define (u64-to-f64-rounds-to?
  [input : u64]
  [constant-bits : u64]
  [expected-bits : u64]) : bool
  (let
    [runtime-bits : u64 (stdlib.math.f64-to-bits (u64-to-f64 input))]
    (and (= runtime-bits expected-bits) (= constant-bits expected-bits))))

(define (u64-to-f32-rounds-to?
  [input : u64]
  [constant-bits : u32]
  [expected-bits : u32]) : bool
  (let
    [runtime-bits : u32 (stdlib.math.f32-to-bits (u64-to-f32 input))]
    (and (= runtime-bits expected-bits) (= constant-bits expected-bits))))

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
  (cond
    ;; Exact binary64 boundaries and ties. The high-half path rounds at a
    ;; ulp of 2048 above 2^63, so 2^63+1024 is the ties-to-even midpoint.
    [(not
        (u64-to-f64-rounds-to?
          (cast 0 : u64)
          (stdlib.math.f64-to-bits (cast (cast 0 : u64) : f64))
          (cast 0x0000000000000000 : u64)))
      1]
    [(not
        (u64-to-f64-rounds-to?
          (cast 1 : u64)
          (stdlib.math.f64-to-bits (cast (cast 1 : u64) : f64))
          (cast 0x3ff0000000000000 : u64)))
      2]
    [(not
        (u64-to-f64-rounds-to?
          (cast 9007199254740991 : u64)
          (stdlib.math.f64-to-bits (cast (cast 9007199254740991 : u64) : f64))
          (cast 0x433fffffffffffff : u64)))
      3]
    [(not
        (u64-to-f64-rounds-to?
          (cast 9007199254740992 : u64)
          (stdlib.math.f64-to-bits (cast (cast 9007199254740992 : u64) : f64))
          (cast 0x4340000000000000 : u64)))
      4]
    [(not
        (u64-to-f64-rounds-to?
          (cast 9007199254740993 : u64)
          (stdlib.math.f64-to-bits (cast (cast 9007199254740993 : u64) : f64))
          (cast 0x4340000000000000 : u64)))
      5]
    [(not
        (u64-to-f64-rounds-to?
          (cast 9007199254740994 : u64)
          (stdlib.math.f64-to-bits (cast (cast 9007199254740994 : u64) : f64))
          (cast 0x4340000000000001 : u64)))
      6]
    [(not
        (u64-to-f64-rounds-to?
          (cast 9223372036854775807 : u64)
          (stdlib.math.f64-to-bits
            (cast (cast 9223372036854775807 : u64) : f64))
          (cast 0x43e0000000000000 : u64)))
      7]
    [(not
        (u64-to-f64-rounds-to?
          (u64-high)
          (stdlib.math.f64-to-bits
            (cast (cast 9223372036854775808 : u64) : f64))
          (cast 0x43e0000000000000 : u64)))
      8]
    [(not
        (u64-to-f64-rounds-to?
          (cast 9223372036854776831 : u64)
          (stdlib.math.f64-to-bits
            (cast (cast 9223372036854776831 : u64) : f64))
          (cast 0x43e0000000000000 : u64)))
      9]
    [(not
        (u64-to-f64-rounds-to?
          (cast 9223372036854776832 : u64)
          (stdlib.math.f64-to-bits
            (cast (cast 9223372036854776832 : u64) : f64))
          (cast 0x43e0000000000000 : u64)))
      10]
    [(not
        (u64-to-f64-rounds-to?
          (cast 9223372036854776833 : u64)
          (stdlib.math.f64-to-bits
            (cast (cast 9223372036854776833 : u64) : f64))
          (cast 0x43e0000000000001 : u64)))
      11]
    [(not
        (u64-to-f64-rounds-to?
          (u64-max)
          (stdlib.math.f64-to-bits
            (cast (cast 18446744073709551615 : u64) : f64))
          (cast 0x43f0000000000000 : u64)))
      12]
    ;; Exact binary32 boundaries and ties. Keep the above-tie integer as a
    ;; u64 until the direct f32 cast; an f64 intermediate loses its low bit.
    [(not
        (u64-to-f32-rounds-to?
          (cast 0 : u64)
          (stdlib.math.f32-to-bits (cast (cast 0 : u64) : f32))
          (cast 0x00000000 : u32)))
      13]
    [(not
        (u64-to-f32-rounds-to?
          (cast 1 : u64)
          (stdlib.math.f32-to-bits (cast (cast 1 : u64) : f32))
          (cast 0x3f800000 : u32)))
      14]
    [(not
        (u64-to-f32-rounds-to?
          (cast 16777215 : u64)
          (stdlib.math.f32-to-bits (cast (cast 16777215 : u64) : f32))
          (cast 0x4b7fffff : u32)))
      15]
    [(not
        (u64-to-f32-rounds-to?
          (cast 16777216 : u64)
          (stdlib.math.f32-to-bits (cast (cast 16777216 : u64) : f32))
          (cast 0x4b800000 : u32)))
      16]
    [(not
        (u64-to-f32-rounds-to?
          (cast 16777217 : u64)
          (stdlib.math.f32-to-bits (cast (cast 16777217 : u64) : f32))
          (cast 0x4b800000 : u32)))
      17]
    [(not
        (u64-to-f32-rounds-to?
          (cast 16777218 : u64)
          (stdlib.math.f32-to-bits (cast (cast 16777218 : u64) : f32))
          (cast 0x4b800001 : u32)))
      18]
    [(not
        (u64-to-f32-rounds-to?
          (cast 9223372036854775807 : u64)
          (stdlib.math.f32-to-bits
            (cast (cast 9223372036854775807 : u64) : f32))
          (cast 0x5f000000 : u32)))
      19]
    [(not
        (u64-to-f32-rounds-to?
          (u64-high)
          (stdlib.math.f32-to-bits
            (cast (cast 9223372036854775808 : u64) : f32))
          (cast 0x5f000000 : u32)))
      20]
    [(not
        (u64-to-f32-rounds-to?
          (cast 9223372586610589695 : u64)
          (stdlib.math.f32-to-bits
            (cast (cast 9223372586610589695 : u64) : f32))
          (cast 0x5f000000 : u32)))
      21]
    [(not
        (u64-to-f32-rounds-to?
          (cast 9223372586610589696 : u64)
          (stdlib.math.f32-to-bits
            (cast (cast 9223372586610589696 : u64) : f32))
          (cast 0x5f000000 : u32)))
      22]
    [(not
        (u64-to-f32-rounds-to?
          (cast 9223372586610589697 : u64)
          (stdlib.math.f32-to-bits
            (cast (cast 9223372586610589697 : u64) : f32))
          (cast 0x5f000001 : u32)))
      23]
    [(not
        (u64-to-f32-rounds-to?
          (cast 9223373136366403584 : u64)
          (stdlib.math.f32-to-bits
            (cast (cast 9223373136366403584 : u64) : f32))
          (cast 0x5f000001 : u32)))
      24]
    [(not
        (u64-to-f32-rounds-to?
          (u64-max)
          (stdlib.math.f32-to-bits
            (cast (cast 18446744073709551615 : u64) : f32))
          (cast 0x5f800000 : u32)))
      25]
    ;; Preserve the non-u64 control which proves narrow unsigned casts do
    ;; not enter the high-half conversion sequence.
    [(not
        (=
          (stdlib.math.f64-to-bits (u8-to-f64 (cast 255 : u8)))
          (cast 0x406fe00000000000 : u64)))
      26]
    ;; Retain one comparison per precision for the assembly-shape guard. The
    ;; exact payload cases above are the semantic oracle.
    [(< (u64-to-f64 (u64-high)) 9223372036854775808.0) 27]
    [(< (u64-to-f32 (u64-high)) 9223372036854775808.0) 28]
    [(not
        (= (f64-to-u64 9223372036854774784.0) (- (u64-high) (cast 1024 : u64))))
      29]
    [(not (= (f64-to-u64 9223372036854775808.0) (u64-high))) 30]
    [(not
        (= (f64-to-u64 9223372036854777856.0) (+ (u64-high) (cast 2048 : u64))))
      31]
    [(not
        (= (f64-to-u64 18446744073709549568.0) (- (u64-max) (cast 2047 : u64))))
      32]
    [(not
        (=
          (f32-to-u64 9223371487098961920.0)
          (- (u64-high) (cast 549755813888 : u64))))
      33]
    [(not (= (f32-to-u64 9223372036854775808.0) (u64-high))) 34]
    [(not
        (=
          (f32-to-u64 9223373136366403584.0)
          (+ (u64-high) (cast 1099511627776 : u64))))
      35]
    [(not
        (=
          (f32-to-u64 18446742974197923840.0)
          (- (u64-max) (cast 1099511627775 : u64))))
      36]
    [else 0]))