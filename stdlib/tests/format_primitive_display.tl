(import stdlib.array)
(import stdlib.format)
(import stdlib.io)
(import stdlib.math)
(import stdlib.string)

(define (display-eq [actual : String] [expected : String]) : bool
  (string.eq actual expected))

(define (integer-display-ok?) : bool
  (and
    (display-eq (format.format "{}" (cast 0 : i8)) "0")
    (display-eq (format.format "{}" (cast 1 : i8)) "1")
    (display-eq (format.format "{}" (cast -128 : i8)) "-128")
    (display-eq (format.format "{}" (cast 127 : i8)) "127")
    (display-eq (format.format "{}" (cast 0 : i16)) "0")
    (display-eq (format.format "{}" (cast 1 : i16)) "1")
    (display-eq (format.format "{}" (cast -32768 : i16)) "-32768")
    (display-eq (format.format "{}" (cast 32767 : i16)) "32767")
    (display-eq (format.format "{}" (cast 0 : i32)) "0")
    (display-eq (format.format "{}" (cast 1 : i32)) "1")
    (display-eq (format.format "{}" (cast -2147483648 : i32)) "-2147483648")
    (display-eq (format.format "{}" (cast 2147483647 : i32)) "2147483647")
    (display-eq (format.format "{}" (cast 0 : i64)) "0")
    (display-eq (format.format "{}" (cast 1 : i64)) "1")
    (display-eq
      (format.format "{}" (cast -9223372036854775808 : i64))
      "-9223372036854775808")
    (display-eq
      (format.format "{}" (cast 9223372036854775807 : i64))
      "9223372036854775807")
    (display-eq (format.format "{}" (cast 0 : u8)) "0")
    (display-eq (format.format "{}" (cast 1 : u8)) "1")
    (display-eq (format.format "{}" (cast 254 : u8)) "254")
    (display-eq (format.format "{}" (cast 255 : u8)) "255")
    (display-eq (format.format "{}" (cast 0 : u16)) "0")
    (display-eq (format.format "{}" (cast 1 : u16)) "1")
    (display-eq (format.format "{}" (cast 65534 : u16)) "65534")
    (display-eq (format.format "{}" (cast 65535 : u16)) "65535")
    (display-eq (format.format "{}" (cast 0 : u32)) "0")
    (display-eq (format.format "{}" (cast 1 : u32)) "1")
    (display-eq (format.format "{}" (cast 4294967294 : u32)) "4294967294")
    (display-eq (format.format "{}" (cast 4294967295 : u32)) "4294967295")
    (display-eq (format.format "{}" (cast 0 : u64)) "0")
    (display-eq (format.format "{}" (cast 1 : u64)) "1")
    (display-eq
      (format.format "{}" (cast 9223372036854775808 : u64))
      "9223372036854775808")
    (display-eq
      (format.format "{}" (cast 18446744073709551615 : u64))
      "18446744073709551615")))

(define (fill-f64-cases
  [bits : (&mut bits (__tl_dyn-array u64))]
  [expected : (&mut expected (__tl_dyn-array String))]) : unit
  (begin
    (set! (array-ref bits 0) 0x0000000000000000)
    (set! (array-ref expected 0) "0")
    (set! (array-ref bits 1) 0x8000000000000000)
    (set! (array-ref expected 1) "-0")
    (set! (array-ref bits 2) 0x3ff8000000000000)
    (set! (array-ref expected 2) "1.5")
    (set! (array-ref bits 3) 0x3ee4f8b588e368f1)
    (set! (array-ref expected 3) "0.00001")
    (set! (array-ref bits 4) 0x4415af1d78b58c40)
    (set! (array-ref expected 4) "100000000000000000000")
    (set! (array-ref bits 5) 0x3ff0000000000001)
    (set! (array-ref expected 5) "1.0000000000000002")
    (set! (array-ref bits 6) 0x3fd3333333333333)
    (set! (array-ref expected 6) "0.3")
    (set! (array-ref bits 7) 0x3fd3333333333334)
    (set! (array-ref expected 7) "0.30000000000000004")
    (set! (array-ref bits 8) 0x42b11802913849d0)
    (set! (array-ref expected 8) "18794819958857.813")
    (set! (array-ref bits 9) 0x0010000000000000)
    (set!
      (array-ref expected 9)
      "0.000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000022250738585072014")
    (set! (array-ref bits 10) 0x0000000000000001)
    (set!
      (array-ref expected 10)
      "0.000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000005")
    (set! (array-ref bits 11) 0x000fffffffffffff)
    (set!
      (array-ref expected 11)
      "0.00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002225073858507201")
    (set! (array-ref bits 12) 0x7fefffffffffffff)
    (set!
      (array-ref expected 12)
      "179769313486231570000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000")
    (set! (array-ref bits 13) 0x7ff0000000000000)
    (set! (array-ref expected 13) "inf")
    (set! (array-ref bits 14) 0xfff0000000000000)
    (set! (array-ref expected 14) "-inf")
    (set! (array-ref bits 15) 0x7ff8000000001234)
    (set! (array-ref expected 15) "NaN")
    (set! (array-ref bits 16) 0xfff8000000001234)
    (set! (array-ref expected 16) "NaN")
    unit))

(define (f64-display-table-ok?) : bool
  (let
    [bits : (__tl_dyn-array u64) (array.make-array u64 17)]
    [expected : (__tl_dyn-array String) (array.make-array String 17)]
    [i : i64 0]
    [ok : bool true]
    (begin
      (fill-f64-cases (&mut bits) (&mut expected))
      (while (and ok (< i 17))
        (begin
          (set!
            ok
            (display-eq
              (format.format "{}" (math.f64-from-bits (array-ref bits i)))
              (clone (array-ref expected i))))
          (set! i (+ i 1))))
      ok)))

(define (fill-f32-cases
  [bits : (&mut bits (__tl_dyn-array u32))]
  [expected : (&mut expected (__tl_dyn-array String))]) : unit
  (begin
    (set! (array-ref bits 0) (cast 0x00000000 : u32))
    (set! (array-ref expected 0) "0")
    (set! (array-ref bits 1) (cast 0x80000000 : u32))
    (set! (array-ref expected 1) "-0")
    (set! (array-ref bits 2) (cast 0x3f9e0651 : u32))
    (set! (array-ref expected 2) "1.2345678")
    (set! (array-ref bits 3) (cast 0x3727c5ac : u32))
    (set! (array-ref expected 3) "0.00001")
    (set! (array-ref bits 4) (cast 0x60ad78ec : u32))
    (set! (array-ref expected 4) "100000000000000000000")
    (set! (array-ref bits 5) (cast 0x3f800001 : u32))
    (set! (array-ref expected 5) "1.0000001")
    (set! (array-ref bits 6) (cast 0x3e99999a : u32))
    (set! (array-ref expected 6) "0.3")
    (set! (array-ref bits 7) (cast 0x00800000 : u32))
    (set!
      (array-ref expected 7)
      "0.000000000000000000000000000000000000011754944")
    (set! (array-ref bits 8) (cast 0x00000001 : u32))
    (set!
      (array-ref expected 8)
      "0.000000000000000000000000000000000000000000001")
    (set! (array-ref bits 9) (cast 0x00000002 : u32))
    (set!
      (array-ref expected 9)
      "0.000000000000000000000000000000000000000000003")
    (set! (array-ref bits 10) (cast 0x007fffff : u32))
    (set!
      (array-ref expected 10)
      "0.000000000000000000000000000000000000011754942")
    (set! (array-ref bits 11) (cast 0x7f7fffff : u32))
    (set! (array-ref expected 11) "340282350000000000000000000000000000000")
    (set! (array-ref bits 12) (cast 0x7f800000 : u32))
    (set! (array-ref expected 12) "inf")
    (set! (array-ref bits 13) (cast 0xff800000 : u32))
    (set! (array-ref expected 13) "-inf")
    (set! (array-ref bits 14) (cast 0x7fc01234 : u32))
    (set! (array-ref expected 14) "NaN")
    (set! (array-ref bits 15) (cast 0xffc01234 : u32))
    (set! (array-ref expected 15) "NaN")
    unit))

(define (f32-display-table-ok?) : bool
  (let
    [bits : (__tl_dyn-array u32) (array.make-array u32 16)]
    [expected : (__tl_dyn-array String) (array.make-array String 16)]
    [i : i64 0]
    [ok : bool true]
    (begin
      (fill-f32-cases (&mut bits) (&mut expected))
      (while (and ok (< i 16))
        (begin
          (set!
            ok
            (display-eq
              (format.format "{}" (math.f32-from-bits (array-ref bits i)))
              (clone (array-ref expected i))))
          (set! i (+ i 1))))
      ok)))

(define (next-random [value : u64]) : u64
  (let
    [next : u64 (bit-xor value (shl value 13))]
    (begin
      (set! next (bit-xor next (shr next 7)))
      (bit-xor next (shl next 17)))))

(define (f64-roundtrip-ok? [bits : u64]) : bool
  (if (= (bit-and (shr bits 52) (cast 0x7ff : u64)) (cast 0x7ff : u64))
    true
    (let
      [text : String (format.format "{}" (math.f64-from-bits bits))]
      (match (io.float-parse-f64 text)
        [(io.IoFloatSomeF64 value) (= (math.f64-to-bits value) bits)]
        [(io.IoFloatNoF64) false]))))

(define (f32-roundtrip-ok? [bits : u32]) : bool
  (if (= (bit-and (shr bits 23) (cast 0xff : u32)) (cast 0xff : u32))
    true
    (let
      [text : String (format.format "{}" (math.f32-from-bits bits))]
      (match (io.float-parse-f64 text)
        [(io.IoFloatSomeF64 value)
          (= (math.f32-to-bits (cast value : f32)) bits)]
        [(io.IoFloatNoF64) false]))))

(define (float-roundtrip-property-ok?) : bool
  (let
    [random : u64 (cast 0x4d595df4d0f33173 : u64)]
    [i : i64 0]
    [ok : bool true]
    (begin
      (while (and ok (< i 256))
        (begin
          (set! random (next-random random))
          (set! ok (f64-roundtrip-ok? random))
          (set! i (+ i 1))))
      (set! i 0)
      (while (and ok (< i 256))
        (begin
          (set! random (next-random random))
          (set! ok (f32-roundtrip-ok? (cast random : u32)))
          (set! i (+ i 1))))
      ok)))

(define (main) : i64
  (if (and
    (integer-display-ok?)
    (f64-display-table-ok?)
    (f32-display-table-ok?)
    (float-roundtrip-property-ok?))
    42
    1))