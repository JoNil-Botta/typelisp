;# Pure scalar math helpers.
;#
;# This module provides runtime-zero-dependency helpers for scalar integer and
;# IEEE-754 float values. Float bit reinterpretation uses private compiler
;# intrinsics.
;# Square root lowers through the private compiler float-sqrt intrinsic to
;# scalar SSE2 on both supported targets.
;#
;# Transcendental functions use freestanding implementations so Linux and
;# Windows behavior cannot accidentally diverge.
;#
;# Runtime helpers are non-allocating and import no runtime or platform externs.
;#
;# Usage: `(import stdlib.math)`
;#
;# ```typelisp
;# (import stdlib.math)
;# (define (main) : i64
;#   (if (= (math.sqrt 81.0) 9.0)
;#     (math.i64-clamp (math.i64-abs -50) 0 42)
;#     1))
;# ```
(import stdlib.comptime)

;: Reinterpret an `f64` as its exact IEEE-754 binary64 bits.
(define (f64-to-bits [value : f64]) : u64
  (__tl_float_to_bits value))

;: Reinterpret IEEE-754 binary64 `bits` as an `f64`.
(define (f64-from-bits [bits : u64]) : f64
  (__tl_float_from_bits bits))

;: Reinterpret an `f32` as its exact IEEE-754 binary32 bits.
(define (f32-to-bits [value : f32]) : u32
  (__tl_float_to_bits value))

;: Reinterpret IEEE-754 binary32 `bits` as an `f32`.
(define (f32-from-bits [bits : u32]) : f32
  (__tl_float_from_bits bits))

;: Construct positive infinity.
(define (f64-positive-infinity) : f64
  (stdlib.math.f64-from-bits 0x7ff0000000000000))

;: Construct negative infinity.
(define (f64-negative-infinity) : f64
  (stdlib.math.f64-from-bits 0xfff0000000000000))

;: Construct a canonical quiet NaN.
(define (f64-quiet-nan) : f64
  (stdlib.math.f64-from-bits 0x7ff8000000000000))

;: Construct binary32 positive infinity.
(define (f32-positive-infinity) : f32
  (stdlib.math.f32-from-bits (cast 0x7f800000 : u32)))

;: Construct binary32 negative infinity.
(define (f32-negative-infinity) : f32
  (stdlib.math.f32-from-bits (cast 0xff800000 : u32)))

;: Construct a canonical binary32 quiet NaN.
(define (f32-quiet-nan) : f32
  (stdlib.math.f32-from-bits (cast 0x7fc00000 : u32)))

;: True when the binary64 sign bit is set, including for negative zero and NaN.
(define (f64-sign-bit? [value : f64]) : bool
  (!=
    (bit-and (stdlib.math.f64-to-bits value) 0x8000000000000000)
    (cast 0 : u64)))

;: True when the binary32 sign bit is set, including for negative zero and NaN.
(define (f32-sign-bit? [value : f32]) : bool
  (!=
    (bit-and (stdlib.math.f32-to-bits value) (cast 0x80000000 : u32))
    (cast 0 : u32)))

;: True when `value` is finite.
(define (f64-finite? [value : f64]) : bool
  (!=
    (bit-and (stdlib.math.f64-to-bits value) 0x7ff0000000000000)
    (cast 0x7ff0000000000000 : u64)))

;: True when `value` is finite.
(define (f32-finite? [value : f32]) : bool
  (!=
    (bit-and (stdlib.math.f32-to-bits value) (cast 0x7f800000 : u32))
    (cast 0x7f800000 : u32)))

;: True when `value` is either infinity.
(define (f64-infinite? [value : f64]) : bool
  (=
    (bit-and (stdlib.math.f64-to-bits value) 0x7fffffffffffffff)
    (cast 0x7ff0000000000000 : u64)))

;: True when `value` is either infinity.
(define (f32-infinite? [value : f32]) : bool
  (=
    (bit-and (stdlib.math.f32-to-bits value) (cast 0x7fffffff : u32))
    (cast 0x7f800000 : u32)))

;: True when `value` is a NaN of either sign and any payload.
(define (f64-nan? [value : f64]) : bool
  (>
    (bit-and (stdlib.math.f64-to-bits value) 0x7fffffffffffffff)
    (cast 0x7ff0000000000000 : u64)))

;: True when `value` is a NaN of either sign and any payload.
(define (f32-nan? [value : f32]) : bool
  (>
    (bit-and (stdlib.math.f32-to-bits value) (cast 0x7fffffff : u32))
    (cast 0x7f800000 : u32)))

;: True when `value` is a normal finite binary64 number.
(define (f64-normal? [value : f64]) : bool
  (let
    [exponent : u64
      (bit-and (stdlib.math.f64-to-bits value) 0x7ff0000000000000)]
    (and
      (!= exponent (cast 0 : u64))
      (!= exponent (cast 0x7ff0000000000000 : u64)))))

;: True when `value` is a normal finite binary32 number.
(define (f32-normal? [value : f32]) : bool
  (let
    [exponent : u32
      (bit-and (stdlib.math.f32-to-bits value) (cast 0x7f800000 : u32))]
    (and (!= exponent (cast 0 : u32)) (!= exponent (cast 0x7f800000 : u32)))))

;: True when `value` is a nonzero subnormal binary64 number.
(define (f64-subnormal? [value : f64]) : bool
  (let
    [magnitude : u64
      (bit-and (stdlib.math.f64-to-bits value) 0x7fffffffffffffff)]
    (and
      (!= magnitude (cast 0 : u64))
      (< magnitude (cast 0x0010000000000000 : u64)))))

;: True when `value` is a nonzero subnormal binary32 number.
(define (f32-subnormal? [value : f32]) : bool
  (let
    [magnitude : u32
      (bit-and (stdlib.math.f32-to-bits value) (cast 0x7fffffff : u32))]
    (and (!= magnitude (cast 0 : u32)) (< magnitude (cast 0x00800000 : u32)))))

;: True when `value` is either binary64 signed zero.
(define (f64-signed-zero? [value : f64]) : bool
  (=
    (bit-and (stdlib.math.f64-to-bits value) 0x7fffffffffffffff)
    (cast 0 : u64)))

;: True when `value` is either binary32 signed zero.
(define (f32-signed-zero? [value : f32]) : bool
  (=
    (bit-and (stdlib.math.f32-to-bits value) (cast 0x7fffffff : u32))
    (cast 0 : u32)))

;: True only for negative binary64 zero.
(define (f64-negative-zero? [value : f64]) : bool
  (= (stdlib.math.f64-to-bits value) (cast 0x8000000000000000 : u64)))

;: True only for positive binary64 zero.
(define (f64-positive-zero? [value : f64]) : bool
  (= (stdlib.math.f64-to-bits value) (cast 0 : u64)))

;: True only for negative binary32 zero.
(define (f32-negative-zero? [value : f32]) : bool
  (= (stdlib.math.f32-to-bits value) (cast 0x80000000 : u32)))

;: True only for positive binary32 zero.
(define (f32-positive-zero? [value : f32]) : bool
  (= (stdlib.math.f32-to-bits value) (cast 0 : u32)))

;: Return `magnitude` with the sign bit of `sign`.
(define (f64-copy-sign [magnitude : f64] [sign : f64]) : f64
  (stdlib.math.f64-from-bits
    (bit-or
      (bit-and (stdlib.math.f64-to-bits magnitude) 0x7fffffffffffffff)
      (bit-and (stdlib.math.f64-to-bits sign) 0x8000000000000000))))

;: Return `magnitude` with the sign bit of `sign`.
(define (f32-copy-sign [magnitude : f32] [sign : f32]) : f32
  (stdlib.math.f32-from-bits
    (bit-or
      (bit-and (stdlib.math.f32-to-bits magnitude) (cast 0x7fffffff : u32))
      (bit-and (stdlib.math.f32-to-bits sign) (cast 0x80000000 : u32)))))

;: Multiply `value` by 2^`exponent` with IEEE-754 overflow, subnormal,
;: underflow, signed-zero, infinity, and NaN behavior.
;:
;: Operation order follows musl `scalbn` at revision
;: `b306b16af15c89a04d8e0c55cac2dadbeb39c083`.
(define (f64-scalbn [value : f64] [exponent : i64]) : f64
  (let
    [y : f64 value]
    [n : i64 exponent]
    (begin
      (if (> n 1023)
        (begin
          (set! y (* y (stdlib.math.f64-from-bits 0x7fe0000000000000)))
          (set! n (- n 1023))
          (if (> n 1023)
            (begin
              (set! y (* y (stdlib.math.f64-from-bits 0x7fe0000000000000)))
              (set! n (- n 1023))
              (if (> n 1023)
                (set! n 1023)
                unit))
            unit))
        (if (< n -1022)
          (begin
            (set! y (* y (stdlib.math.f64-from-bits 0x0360000000000000)))
            (set! n (+ n 969))
            (if (< n -1022)
              (begin
                (set! y (* y (stdlib.math.f64-from-bits 0x0360000000000000)))
                (set! n (+ n 969))
                (if (< n -1022)
                  (set! n -1022)
                  unit))
              unit))
          unit))
      (* y (stdlib.math.f64-from-bits (shl (cast (+ 1023 n) : u64) 52))))))

;: Binary32 `scalbn`, following musl `scalbnf` at revision
;: `b306b16af15c89a04d8e0c55cac2dadbeb39c083`.
(define (f32-scalbn [value : f32] [exponent : i64]) : f32
  (let
    [y : f32 value]
    [n : i64 exponent]
    (begin
      (if (> n 127)
        (begin
          (set! y (* y (stdlib.math.f32-from-bits (cast 0x7f000000 : u32))))
          (set! n (- n 127))
          (if (> n 127)
            (begin
              (set! y (* y (stdlib.math.f32-from-bits (cast 0x7f000000 : u32))))
              (set! n (- n 127))
              (if (> n 127)
                (set! n 127)
                unit))
            unit))
        (if (< n -126)
          (begin
            (set! y (* y (stdlib.math.f32-from-bits (cast 0x0c800000 : u32))))
            (set! n (+ n 102))
            (if (< n -126)
              (begin
                (set!
                  y
                  (* y (stdlib.math.f32-from-bits (cast 0x0c800000 : u32))))
                (set! n (+ n 102))
                (if (< n -126)
                  (set! n -126)
                  unit))
              unit))
          unit))
      (* y (stdlib.math.f32-from-bits (shl (cast (+ 127 n) : u32) 23))))))

;; The exponential implementation below follows musl `exp`/`expf` and their
;; data tables at revision b306b16af15c89a04d8e0c55cac2dadbeb39c083.
;; Tail corrections are shortest decimals folded to exact IEEE-754 payloads.
;; Adjusted scales stay raw integer words for exponent arithmetic; payloads and
;; operation order remain fixed because both are part of the stated bounds.
;: Internal exact tail payload and adjusted scale bits for one binary64 entry.
(defstruct MathExpF64TableEntry
  (tail-bits u64)
  (scale-bits u64))

;: Return {tail payload, adjusted 2^(index/128) bits} from musl exp_data.c.
;:
;: Tails stay in the `u64` ABI and are read with `f64-from-bits`; scales remain
;: raw words. In-code storage avoids a global; binary32 reuses every fourth row.
(define (math-exp-f64-table-entry [index : i64]) : MathExpF64TableEntry
  (cond
    [(= index 0)
      (MathExpF64TableEntry (stdlib.math.f64-to-bits 0.0) 0x3ff0000000000000)]
    [(= index 1)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits 9.447885451727066e-17)
        0x3feff63da9fb3335)]
    [(= index 2)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits -1.507066976926039e-17)
        0x3fefec9a3e778061)]
    [(= index 3)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits -5.679155082825012e-17)
        0x3fefe315e86e7f85)]
    [(= index 4)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits 4.9997448722726326e-17)
        0x3fefd9b0d3158574)]
    [(= index 5)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits -4.823683599994895e-17)
        0x3fefd06b29ddf6de)]
    [(= index 6)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits 7.357846871247418e-18)
        0x3fefc74518759bc8)]
    [(= index 7)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits 5.773230223741951e-17)
        0x3fefbe3ecac6f383)]
    [(= index 8)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits 8.189317638195515e-17)
        0x3fefb5586cf9890f)]
    [(= index 9)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits 5.326891139980878e-17)
        0x3fefac922b7247f7)]
    [(= index 10)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits 1.6665881442326747e-18)
        0x3fefa3ec32d3d1a2)]
    [(= index 11)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits -1.128113245461828e-17)
        0x3fef9b66affed31b)]
    [(= index 12)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits -7.402825309426177e-17)
        0x3fef9301d0125b51)]
    [(= index 13)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits -3.578659767309563e-18)
        0x3fef8abdc06c31cc)]
    [(= index 14)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits -6.170654745608695e-17)
        0x3fef829aaea92de0)]
    [(= index 15)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits 2.919139999949279e-17)
        0x3fef7a98c8a58e51)]
    [(= index 16)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits -2.7939114859515733e-17)
        0x3fef72b83c7d517b)]
    [(= index 17)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits -5.399285355184285e-17)
        0x3fef6af9388c8dea)]
    [(= index 18)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits 4.776959425256223e-17)
        0x3fef635beb6fcb75)]
    [(= index 19)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits -7.927701432338473e-17)
        0x3fef5be084045cd4)]
    [(= index 20)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits 9.341710609905046e-17)
        0x3fef54873168b9aa)]
    [(= index 21)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits -5.534520675707472e-17)
        0x3fef4d5022fcd91d)]
    [(= index 22)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits 4.585670326662351e-17)
        0x3fef463b88628cd6)]
    [(= index 23)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits 2.8582430411116143e-17)
        0x3fef3f49917ddc96)]
    [(= index 24)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits 7.826573258636076e-17)
        0x3fef387a6e756238)]
    [(= index 25)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits 4.053626906769216e-17)
        0x3fef31ce4fb2a63f)]
    [(= index 26)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits 2.823784425951061e-17)
        0x3fef2b4565e27cdd)]
    [(= index 27)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits -7.882802262487991e-17)
        0x3fef24dfe1f56381)]
    [(= index 28)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits 3.2904726646008416e-17)
        0x3fef1e9df51fdee1)]
    [(= index 29)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits -1.5792094703347882e-18)
        0x3fef187fd0dad990)]
    [(= index 30)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits 4.721368121170128e-17)
        0x3fef1285a6e4030b)]
    [(= index 31)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits 1.3045277096919659e-17)
        0x3fef0cafa93e2f56)]
    [(= index 32)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits 3.3484623336251524e-17)
        0x3fef06fe0a31b715)]
    [(= index 33)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits 3.8611199774925664e-17)
        0x3fef0170fc4cd831)]
    [(= index 34)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits 5.527550048505249e-17)
        0x3feefc08b26416ff)]
    [(= index 35)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits -3.927184172445234e-17)
        0x3feef6c55f929ff1)]
    [(= index 36)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits -6.346552106729483e-17)
        0x3feef1a7373aa9cb)]
    [(= index 37)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits -8.684417614865944e-17)
        0x3feeecae6d05d866)]
    [(= index 38)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits -1.5456342819397733e-17)
        0x3feee7db34e59ff7)]
    [(= index 39)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits -8.70763476495455e-17)
        0x3feee32dc313a8e5)]
    [(= index 40)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits 3.750854201303127e-17)
        0x3feedea64c123422)]
    [(= index 41)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits -6.616854503526488e-17)
        0x3feeda4504ac801c)]
    [(= index 42)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits -5.346099009198751e-18)
        0x3feed60a21f72e2a)]
    [(= index 43)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits -2.443726321015018e-17)
        0x3feed1f5d950a897)]
    [(= index 44)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits 2.1023049675215714e-18)
        0x3feece086061892d)]
    [(= index 45)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits 7.771067937501065e-17)
        0x3feeca41ed1d0057)]
    [(= index 46)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits 1.3357510088834541e-17)
        0x3feec6a2b5c13cd0)]
    [(= index 47)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits 6.938291696959204e-17)
        0x3feec32af0d7d3de)]
    [(= index 48)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits 1.9572585293112036e-17)
        0x3feebfdad5362a27)]
    [(= index 49)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits 6.632256961675804e-17)
        0x3feebcb299fddd0d)]
    [(= index 50)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits -5.478069123926778e-17)
        0x3feeb9b2769d2ca7)]
    [(= index 51)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits -4.140839310392624e-17)
        0x3feeb6daa2cf6642)]
    [(= index 52)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits -2.1571477251208752e-17)
        0x3feeb42b569d4f82)]
    [(= index 53)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits -3.8287766552120535e-17)
        0x3feeb1a4ca5d920f)]
    [(= index 54)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits 6.663804589232195e-17)
        0x3feeaf4736b527da)]
    [(= index 55)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits 2.3936187400285282e-17)
        0x3feead12d497c7fd)]
    [(= index 56)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits 5.68648095791174e-17)
        0x3feeab07dd485429)]
    [(= index 57)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits 1.1264523354521684e-18)
        0x3feea9268a5946b7)]
    [(= index 58)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits 7.007875046906994e-17)
        0x3feea76f15ad2148)]
    [(= index 59)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits -5.0119214278381254e-17)
        0x3feea5e1b976dc09)]
    [(= index 60)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits -4.8923067513522756e-17)
        0x3feea47eb03a5585)]
    [(= index 61)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits -3.5260089953269434e-17)
        0x3feea34634ccc320)]
    [(= index 62)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits -6.872303720902018e-17)
        0x3feea23882552225)]
    [(= index 63)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits 5.001446664133532e-18)
        0x3feea155d44ca973)]
    [(= index 64)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits -6.835808657661922e-17)
        0x3feea09e667f3bcd)]
    [(= index 65)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits -1.1307344092910212e-17)
        0x3feea012750bdabf)]
    [(= index 66)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits -8.416011634717156e-18)
        0x3fee9fb23c651a2f)]
    [(= index 67)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits -2.9247977035436566e-17)
        0x3fee9f7df9519484)]
    [(= index 68)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits -2.092304381843353e-17)
        0x3fee9f75e8ec5f74)]
    [(= index 69)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits -3.9778645875427124e-17)
        0x3fee9f9a48a58174)]
    [(= index 70)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits -3.833464968654295e-17)
        0x3fee9feb564267c9)]
    [(= index 71)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits 5.763611164480894e-17)
        0x3feea0694fde5d3f)]
    [(= index 72)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits -2.3591094770850053e-17)
        0x3feea11473eb0187)]
    [(= index 73)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits 7.260074661098575e-17)
        0x3feea1ed0130c132)]
    [(= index 74)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits 9.50689710108796e-18)
        0x3feea2f336cf4e62)]
    [(= index 75)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits -4.272956133839906e-17)
        0x3feea427543e1a12)]
    [(= index 76)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits -6.735219232374683e-17)
        0x3feea589994cce13)]
    [(= index 77)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits -2.8396044410430936e-17)
        0x3feea71a4623c7ad)]
    [(= index 78)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits -7.226635472101257e-17)
        0x3feea8d99b4492ed)]
    [(= index 79)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits 5.786121003395918e-17)
        0x3feeaac7d98a6699)]
    [(= index 80)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits 5.1548301170786783e-17)
        0x3feeace5422aa0db)]
    [(= index 81)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits -9.416257568878152e-18)
        0x3feeaf3216b5448c)]
    [(= index 82)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits 2.4253985766689806e-17)
        0x3feeb1ae99157736)]
    [(= index 83)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits -6.604314051707707e-17)
        0x3feeb45b0b91ffc6)]
    [(= index 84)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits -6.432131775424189e-18)
        0x3feeb737b0cdc5e5)]
    [(= index 85)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits -1.2204007601863921e-17)
        0x3feeba44cbc8520f)]
    [(= index 86)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits -6.336161863401293e-17)
        0x3feebd829fde4e50)]
    [(= index 87)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits -3.7800879246373815e-17)
        0x3feec0f170ca07ba)]
    [(= index 88)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits 1.5341410053603723e-17)
        0x3feec49182a3f090)]
    [(= index 89)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits 1.2932855580427452e-17)
        0x3feec86319e32323)]
    [(= index 90)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits -4.123367330661149e-17)
        0x3feecc667b5de565)]
    [(= index 91)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits 4.703083974463456e-17)
        0x3feed09bec4a2d33)]
    [(= index 92)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits -6.152602891550265e-17)
        0x3feed503b23e255d)]
    [(= index 93)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits 5.827849326195279e-17)
        0x3feed99e1330b358)]
    [(= index 94)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits 3.540948262646183e-17)
        0x3feede6b5579fdbf)]
    [(= index 95)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits -3.2741571320938764e-17)
        0x3feee36bbfd3f37a)]
    [(= index 96)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits 4.875160526227062e-17)
        0x3feee89f995ad3ad)]
    [(= index 97)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits -5.718569790077838e-17)
        0x3feeee07298db666)]
    [(= index 98)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits -4.719539664590972e-18)
        0x3feef3a2b84f15fb)]
    [(= index 99)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits -5.773451958805706e-17)
        0x3feef9728de5593a)]
    [(= index 100)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits -1.0772487078934056e-17)
        0x3feeff76f2fb5e47)]
    [(= index 101)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits -6.221808618533911e-17)
        0x3fef05b030a1064a)]
    [(= index 102)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits 1.821405440362259e-17)
        0x3fef0c1e904bc1d2)]
    [(= index 103)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits -6.155536546227639e-17)
        0x3fef12c25bd71e09)]
    [(= index 104)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits 1.685487290628973e-17)
        0x3fef199bdd85529c)]
    [(= index 105)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits 5.3581249177694816e-17)
        0x3fef20ab5fffd07a)]
    [(= index 106)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits 3.621615935336894e-17)
        0x3fef27f12e57d14b)]
    [(= index 107)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits 8.588379527574144e-18)
        0x3fef2f6d9406e7b5)]
    [(= index 108)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits 1.01562190116415e-17)
        0x3fef3720dcef9069)]
    [(= index 109)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits -2.869134889187244e-17)
        0x3fef3f0b555dc3fa)]
    [(= index 110)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits -5.495118966122005e-17)
        0x3fef472d4a07897c)]
    [(= index 111)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits -5.56965572431627e-17)
        0x3fef4f87080d89f2)]
    [(= index 112)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits 1.790126907604513e-17)
        0x3fef5818dcfba487)]
    [(= index 113)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits -3.2211766346200164e-17)
        0x3fef60e316c98398)]
    [(= index 114)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits 5.265370768556274e-17)
        0x3fef69e603db3285)]
    [(= index 115)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits 3.5089866402403033e-17)
        0x3fef7321f301b460)]
    [(= index 116)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits -3.266924100901318e-17)
        0x3fef7c97337b9b5f)]
    [(= index 117)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits -4.3657593008079375e-17)
        0x3fef864614f5a129)]
    [(= index 118)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits 1.7963932659833022e-17)
        0x3fef902ee78b3ff6)]
    [(= index 119)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits 3.4300925275214166e-17)
        0x3fef9a51fbc74c83)]
    [(= index 120)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits -5.545065618639427e-17)
        0x3fefa4afa2a490da)]
    [(= index 121)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits -5.149009745457733e-17)
        0x3fefaf482d8e67f1)]
    [(= index 122)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits 5.336805878514151e-17)
        0x3fefba1bee615a27)]
    [(= index 123)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits 3.498978661192973e-17)
        0x3fefc52b376bba97)]
    [(= index 124)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits 4.5784915277060095e-17)
        0x3fefd0765b6e4540)]
    [(= index 125)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits -5.241934575393899e-17)
        0x3fefdbfdad9cbe14)]
    [(= index 126)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits 2.0414278897578303e-17)
        0x3fefe7c1819e90d8)]
    [(= index 127)
      (MathExpF64TableEntry
        (stdlib.math.f64-to-bits 4.124842848606488e-18)
        0x3feff3c22b8f71f1)]
    [else (MathExpF64TableEntry 0 0)]))

;: Complete a binary64 result whose table scale may overflow or underflow.
(define (math-exp-f64-special [tmp : f64] [scale-bits : u64] [k-bits : u64]) : f64
  (if (= (bit-and k-bits (cast 0x80000000 : u64)) (cast 0 : u64))
    (let
      [adjusted-bits : u64 (- scale-bits (shl (cast 1009 : u64) 52))]
      [scale : f64 (stdlib.math.f64-from-bits adjusted-bits)]
      (* (stdlib.math.f64-from-bits 0x7f00000000000000) (+ scale (* scale tmp))))
    (let
      [adjusted-bits : u64 (+ scale-bits (shl (cast 1022 : u64) 52))]
      [scale : f64 (stdlib.math.f64-from-bits adjusted-bits)]
      [y : f64 (+ scale (* scale tmp))]
      (begin
        (if (< y 1.0)
          (let
            [lo : f64 (+ (- scale y) (* scale tmp))]
            [hi : f64 (+ 1.0 y)]
            (begin
              (set! lo (+ (+ (- 1.0 hi) y) lo))
              (set! y (- (+ hi lo) 1.0))))
          unit)
        (* (stdlib.math.f64-from-bits 0x0010000000000000) y)))))

;: Return e^`value` as binary64 without allocation or platform math calls.
;:
;: The implementation uses 128-way table reduction and a degree-five
;: polynomial. In default round-to-nearest mode its worst-case error is below
;: one ULP. Both signed zeros map to exactly one, finite overflow maps to
;: positive infinity, underflow is gradual through subnormals, negative
;: infinity maps to zero, positive infinity is unchanged, and NaNs remain NaN.
(define (f64-exp [value : f64]) : f64
  (let
    [bits : u64 (stdlib.math.f64-to-bits value)]
    [magnitude-top : u64 (bit-and (shr bits 52) (cast 0x7ff : u64))]
    (if (< magnitude-top (cast 0x3c9 : u64))
      (+ 1.0 value)
      (if (>= magnitude-top (cast 0x409 : u64))
        (cond
          [(= bits (cast 0xfff0000000000000 : u64)) 0.0]
          [(>= magnitude-top (cast 0x7ff : u64)) (+ 1.0 value)]
          [(!= (bit-and bits 0x8000000000000000) (cast 0 : u64)) 0.0]
          [else (stdlib.math.f64-positive-infinity)])
        (let
          [z : f64 (* (stdlib.math.f64-from-bits 0x40671547652b82fe) value)]
          [rounded : f64 (+ z (stdlib.math.f64-from-bits 0x4338000000000000))]
          [k-bits : u64 (stdlib.math.f64-to-bits rounded)]
          [k : f64 (- rounded (stdlib.math.f64-from-bits 0x4338000000000000))]
          [r : f64
            (+
              (+ value (* k (stdlib.math.f64-from-bits 0xbf762e42fefa0000)))
              (* k (stdlib.math.f64-from-bits 0xbd0cf79abc9e3b3a)))]
          [index : i64 (cast (% k-bits (cast 128 : u64)) : i64)]
          [entry : MathExpF64TableEntry (math-exp-f64-table-entry index)]
          [scale-bits : u64 (+ (struct-get entry scale-bits) (shl k-bits 45))]
          [tail : f64 (stdlib.math.f64-from-bits (struct-get entry tail-bits))]
          [r2 : f64 (* r r)]
          [tmp : f64
            (+
              (+
                (+ tail r)
                (*
                  r2
                  (+
                    (stdlib.math.f64-from-bits 0x3fdffffffffffdbd)
                    (* r (stdlib.math.f64-from-bits 0x3fc555555555543c)))))
              (*
                (* r2 r2)
                (+
                  (stdlib.math.f64-from-bits 0x3fa55555cf172b91)
                  (* r (stdlib.math.f64-from-bits 0x3f81111167a4d017)))))]
          (if (>= magnitude-top (cast 0x408 : u64))
            (math-exp-f64-special tmp scale-bits k-bits)
            (let
              [scale : f64 (stdlib.math.f64-from-bits scale-bits)]
              (+ scale (* scale tmp)))))))))

;: Evaluate the finite, non-extreme binary32 exponential reduction.
(define (math-exp-f32-finite [value : f32]) : f32
  (let
    [x : f64 (cast value : f64)]
    [z : f64 (* (stdlib.math.f64-from-bits 0x40471547652b82fe) x)]
    [rounded : f64 (+ z (stdlib.math.f64-from-bits 0x4338000000000000))]
    [k-bits : u64 (stdlib.math.f64-to-bits rounded)]
    [k : f64 (- rounded (stdlib.math.f64-from-bits 0x4338000000000000))]
    [r : f64 (- z k)]
    [entry : MathExpF64TableEntry
      (math-exp-f64-table-entry (* (cast (% k-bits (cast 32 : u64)) : i64) 4))]
    [scale-bits : u64 (+ (struct-get entry scale-bits) (shl k-bits 47))]
    [scale : f64 (stdlib.math.f64-from-bits scale-bits)]
    [p : f64
      (+
        (* (stdlib.math.f64-from-bits 0x3ebc6af84b912394) r)
        (stdlib.math.f64-from-bits 0x3f2ebfce50fac4f3))]
    [r2 : f64 (* r r)]
    [y : f64 (+ (* (stdlib.math.f64-from-bits 0x3f962e42ff0c52d6) r) 1.0)]
    (cast (* (+ (* p r2) y) scale) : f32)))

;: Return e^`value` as binary32 without allocation or platform math calls.
;:
;: This uses a 32-way table reduction and degree-three polynomial evaluated in
;: binary64 before the final binary32 rounding. Its round-to-nearest error is
;: at most one ULP and special-value behavior matches `f64-exp`.
(define (f32-exp [value : f32]) : f32
  (let
    [bits : u32 (stdlib.math.f32-to-bits value)]
    [magnitude-top : u32 (bit-and (shr bits 20) (cast 0x7ff : u32))]
    (if (>= magnitude-top (cast 0x42b : u32))
      (cond
        [(= bits (cast 0xff800000 : u32)) (cast 0.0 : f32)]
        [(>= magnitude-top (cast 0x7f8 : u32)) (+ value value)]
        [(> value (stdlib.math.f32-from-bits (cast 0x42b17217 : u32)))
          (stdlib.math.f32-positive-infinity)]
        [(< value (stdlib.math.f32-from-bits (cast 0xc2cff1b4 : u32)))
          (stdlib.math.f32-from-bits (cast 0 : u32))]
        [else (math-exp-f32-finite value)])
      (math-exp-f32-finite value))))

;: Return e^`value` for an `f64` or `f32` expression, preserving its type.
(defmacro (exp [value : comptime.Expr]) : comptime.Expr
  (match (type-kind (comptime.expr-type value))
    ["f64" `(stdlib.math.f64-exp ,value)]
    ["f32" `(stdlib.math.f32-exp ,value)]
    [_
      (comptime.comptime-error
        (comptime.string-append
          "math.exp: expected f64 or f32, found "
          (type-kind (comptime.expr-type value))))]))

;; The logarithm implementation below follows musl log/logf and their data
;; tables at revision b306b16af15c89a04d8e0c55cac2dadbeb39c083.
;; Table fields remain exact IEEE-754 u64 bit patterns; readable decimal
;; initializers fold through `f64-to-bits`. Reduction order remains fixed.
;: Internal binary64 logarithm reduction constants for one table interval.
(defstruct MathLogF64TableEntry
  (invc-bits u64)
  (logc-bits u64)
  (chi-bits u64)
  (clo-bits u64))

;: Return the exact musl binary64 logarithm constants for interval index.
(define (math-log-f64-table-entry [index : i64]) : MathLogF64TableEntry
  (cond
    [(= index 0)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 1.4504249240398293)
        (stdlib.math.f64-to-bits -0.37185656456335892)
        (stdlib.math.f64-to-bits 0.68945312744263043)
        (stdlib.math.f64-to-bits 2.6029065281053499e-17))]
    [(= index 1)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 1.4422535083272761)
        (stdlib.math.f64-to-bits -0.36620682668944937)
        (stdlib.math.f64-to-bits 0.69335938115331663)
        (stdlib.math.f64-to-bits 5.1607448519931415e-17))]
    [(= index 2)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 1.4341736174350004)
        (stdlib.math.f64-to-bits -0.36058880697919449)
        (stdlib.math.f64-to-bits 0.69726565029726739)
        (stdlib.math.f64-to-bits 5.2906724148878689e-17))]
    [(= index 3)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 1.4261838163299949)
        (stdlib.math.f64-to-bits -0.35500221714198688)
        (stdlib.math.f64-to-bits 0.70117188860921476)
        (stdlib.math.f64-to-bits 7.8010306348060135e-18))]
    [(= index 4)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 1.4182825527052965)
        (stdlib.math.f64-to-bits -0.34944666968829097)
        (stdlib.math.f64-to-bits 0.70507812289769389)
        (stdlib.math.f64-to-bits -2.471355337688684e-17))]
    [(= index 5)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 1.4104682921759335)
        (stdlib.math.f64-to-bits -0.34392177136032842)
        (stdlib.math.f64-to-bits 0.7089843887644558)
        (stdlib.math.f64-to-bits -4.6413389636862956e-17))]
    [(= index 6)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 1.4027396147468003)
        (stdlib.math.f64-to-bits -0.33842719212611883)
        (stdlib.math.f64-to-bits 0.71289068155425528)
        (stdlib.math.f64-to-bits 3.3387408065940366e-17))]
    [(= index 7)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 1.3950954438932313)
        (stdlib.math.f64-to-bits -0.33296283149434203)
        (stdlib.math.f64-to-bits 0.71679683592783028)
        (stdlib.math.f64-to-bits -2.6454587338050098e-17))]
    [(= index 8)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 1.3875338232485754)
        (stdlib.math.f64-to-bits -0.32752794345742586)
        (stdlib.math.f64-to-bits 0.7207031520563163)
        (stdlib.math.f64-to-bits 2.4284096334522285e-17))]
    [(= index 9)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 1.3800539211058593)
        (stdlib.math.f64-to-bits -0.32212257167088865)
        (stdlib.math.f64-to-bits 0.72460936830546729)
        (stdlib.math.f64-to-bits 4.8578243503198198e-17))]
    [(= index 10)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 1.3726542695419708)
        (stdlib.math.f64-to-bits -0.3167462884799761)
        (stdlib.math.f64-to-bits 0.72851556447180355)
        (stdlib.math.f64-to-bits -1.3014776598894487e-17))]
    [(= index 11)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 1.3653332798446802)
        (stdlib.math.f64-to-bits -0.3113985598928366)
        (stdlib.math.f64-to-bits 0.73242190369355065)
        (stdlib.math.f64-to-bits -1.0402317671225898e-17))]
    [(= index 12)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 1.358090204587874)
        (stdlib.math.f64-to-bits -0.30607945151655258)
        (stdlib.math.f64-to-bits 0.73632811474658999)
        (stdlib.math.f64-to-bits 3.0782914274674313e-17))]
    [(= index 13)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 1.3509234892132138)
        (stdlib.math.f64-to-bits -0.30078842466764399)
        (stdlib.math.f64-to-bits 0.74023437151307969)
        (stdlib.math.f64-to-bits -1.4304998976623033e-17))]
    [(= index 14)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 1.3438320840699889)
        (stdlib.math.f64-to-bits -0.29552529684769979)
        (stdlib.math.f64-to-bits 0.74414059007384026)
        (stdlib.math.f64-to-bits -2.8625955785571303e-17))]
    [(= index 15)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 1.3368146974742003)
        (stdlib.math.f64-to-bits -0.29028969275850613)
        (stdlib.math.f64-to-bits 0.74804683243640002)
        (stdlib.math.f64-to-bits 5.1609093535635645e-17))]
    [(= index 16)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 1.3298701146777361)
        (stdlib.math.f64-to-bits -0.28508127932775551)
        (stdlib.math.f64-to-bits 0.75195313359028848)
        (stdlib.math.f64-to-bits 4.423423949536319e-17))]
    [(= index 17)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 1.3229973391611061)
        (stdlib.math.f64-to-bits -0.27989987391470095)
        (stdlib.math.f64-to-bits 0.75585941891167063)
        (stdlib.math.f64-to-bits -4.6830167620995081e-17))]
    [(= index 18)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 1.316195352741367)
        (stdlib.math.f64-to-bits -0.27474526621870154)
        (stdlib.math.f64-to-bits 0.75976563655023055)
        (stdlib.math.f64-to-bits 4.4667420075147718e-17))]
    [(= index 19)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 1.3094628125672239)
        (stdlib.math.f64-to-bits -0.26961698637012432)
        (stdlib.math.f64-to-bits 0.76367193508877373)
        (stdlib.math.f64-to-bits -4.8134498775190266e-17))]
    [(= index 20)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 1.3027990455471041)
        (stdlib.math.f64-to-bits -0.26451506180308115)
        (stdlib.math.f64-to-bits 0.76757808767050095)
        (stdlib.math.f64-to-bits -4.3371015350542286e-17))]
    [(= index 21)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 1.2962024229438942)
        (stdlib.math.f64-to-bits -0.25943877627673828)
        (stdlib.math.f64-to-bits 0.77148443969795355)
        (stdlib.math.f64-to-bits -2.5156444722517071e-17))]
    [(= index 22)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 1.2896726275815547)
        (stdlib.math.f64-to-bits -0.25438840909816918)
        (stdlib.math.f64-to-bits 0.77539057479667517)
        (stdlib.math.f64-to-bits -4.163636184961329e-17))]
    [(= index 23)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 1.2832080305745537)
        (stdlib.math.f64-to-bits -0.24936321635129843)
        (stdlib.math.f64-to-bits 0.77929686860847658)
        (stdlib.math.f64-to-bits 3.3837161384165165e-17))]
    [(= index 24)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 1.276807885983376)
        (stdlib.math.f64-to-bits -0.24436312405975968)
        (stdlib.math.f64-to-bits 0.78320318270106604)
        (stdlib.math.f64-to-bits 4.3792065650567583e-17))]
    [(= index 25)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 1.2704714060687552)
        (stdlib.math.f64-to-bits -0.23938801747897287)
        (stdlib.math.f64-to-bits 0.78710941090309128)
        (stdlib.math.f64-to-bits 2.7322930976146396e-17))]
    [(= index 26)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 1.2641976054949482)
        (stdlib.math.f64-to-bits -0.23443761696705678)
        (stdlib.math.f64-to-bits 0.79101557830311531)
        (stdlib.math.f64-to-bits -5.4636612253640457e-17))]
    [(= index 27)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 1.2579853575148821)
        (stdlib.math.f64-to-bits -0.22951151871518505)
        (stdlib.math.f64-to-bits 0.79492181210715718)
        (stdlib.math.f64-to-bits -1.4320502634189868e-17))]
    [(= index 28)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 1.2518337750655457)
        (stdlib.math.f64-to-bits -0.2246094963439873)
        (stdlib.math.f64-to-bits 0.79882810315422292)
        (stdlib.math.f64-to-bits -4.0766731402809024e-17))]
    [(= index 29)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 1.2457421919097305)
        (stdlib.math.f64-to-bits -0.21973149037705753)
        (stdlib.math.f64-to-bits 0.80273431091467962)
        (stdlib.math.f64-to-bits -4.0338264352540086e-17))]
    [(= index 30)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 1.2397094966625508)
        (stdlib.math.f64-to-bits -0.2148770752847895)
        (stdlib.math.f64-to-bits 0.80664059014803224)
        (stdlib.math.f64-to-bits 1.7241428071650815e-18))]
    [(= index 31)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 1.2337348463589233)
        (stdlib.math.f64-to-bits -0.21004602910363701)
        (stdlib.math.f64-to-bits 0.81054693636259334)
        (stdlib.math.f64-to-bits -4.5534218930924523e-17))]
    [(= index 32)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 1.2278176973028803)
        (stdlib.math.f64-to-bits -0.20523836373934046)
        (stdlib.math.f64-to-bits 0.8144531571720115)
        (stdlib.math.f64-to-bits 1.8212169205891421e-17))]
    [(= index 33)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 1.2219570190618474)
        (stdlib.math.f64-to-bits -0.20045368751368642)
        (stdlib.math.f64-to-bits 0.81835938940613961)
        (stdlib.math.f64-to-bits 4.9864288025894273e-17))]
    [(= index 34)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 1.2161519732977757)
        (stdlib.math.f64-to-bits -0.1956917537758045)
        (stdlib.math.f64-to-bits 0.82226565590182965)
        (stdlib.math.f64-to-bits 4.3359904167266887e-17))]
    [(= index 35)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 1.2104018095009725)
        (stdlib.math.f64-to-bits -0.19095237845203883)
        (stdlib.math.f64-to-bits 0.82617193080063434)
        (stdlib.math.f64-to-bits -5.4220014716611272e-17))]
    [(= index 36)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 1.204705805718973)
        (stdlib.math.f64-to-bits -0.18623539250290833)
        (stdlib.math.f64-to-bits 0.83007817780308302)
        (stdlib.math.f64-to-bits -5.3336037289290352e-17))]
    [(= index 37)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 1.1990631185441964)
        (stdlib.math.f64-to-bits -0.18154051731551135)
        (stdlib.math.f64-to-bits 0.83398445380766739)
        (stdlib.math.f64-to-bits -1.1270648442682386e-17))]
    [(= index 38)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 1.1934733004462308)
        (stdlib.math.f64-to-bits -0.17686779574319189)
        (stdlib.math.f64-to-bits 0.83789054989844136)
        (stdlib.math.f64-to-bits -3.1651267348003982e-17))]
    [(= index 39)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 1.1879350812847385)
        (stdlib.math.f64-to-bits -0.17221657406412305)
        (stdlib.math.f64-to-bits 0.84179684206186689)
        (stdlib.math.f64-to-bits 1.1286283062565865e-17))]
    [(= index 40)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 1.1824481322833125)
        (stdlib.math.f64-to-bits -0.16758697765942543)
        (stdlib.math.f64-to-bits 0.84570305681738078)
        (stdlib.math.f64-to-bits 5.643595964448442e-18))]
    [(= index 41)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 1.1770114976921955)
        (stdlib.math.f64-to-bits -0.16297859687290384)
        (stdlib.math.f64-to-bits 0.84960937251737334)
        (stdlib.math.f64-to-bits -2.1687834632368187e-17))]
    [(= index 42)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 1.1716248121809465)
        (stdlib.math.f64-to-bits -0.15839151377804228)
        (stdlib.math.f64-to-bits 0.85351555344626773)
        (stdlib.math.f64-to-bits -2.2548234217914977e-17))]
    [(= index 43)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 1.1662869231674715)
        (stdlib.math.f64-to-bits -0.15382513241456763)
        (stdlib.math.f64-to-bits 0.85742194320771459)
        (stdlib.math.f64-to-bits 4.6832605563531392e-17))]
    [(= index 44)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 1.1609977486762766)
        (stdlib.math.f64-to-bits -0.14927976358922024)
        (stdlib.math.f64-to-bits 0.86132811294437062)
        (stdlib.math.f64-to-bits 2.5148296884122795e-17))]
    [(= index 45)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 1.1557563220795803)
        (stdlib.math.f64-to-bits -0.14475495398119165)
        (stdlib.math.f64-to-bits 0.86523428935320534)
        (stdlib.math.f64-to-bits -8.6721875709494672e-18))]
    [(= index 46)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 1.1505619105480347)
        (stdlib.math.f64-to-bits -0.14025044090817573)
        (stdlib.math.f64-to-bits 0.86914053979388284)
        (stdlib.math.f64-to-bits -1.2576268285559751e-17))]
    [(= index 47)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 1.1454138888505974)
        (stdlib.math.f64-to-bits -0.13576604666855019)
        (stdlib.math.f64-to-bits 0.87304686081943916)
        (stdlib.math.f64-to-bits -2.9930851265147998e-17))]
    [(= index 48)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 1.1403118773746559)
        (stdlib.math.f64-to-bits -0.1313018016355727)
        (stdlib.math.f64-to-bits 0.87695306857831168)
        (stdlib.math.f64-to-bits 4.8148015076816437e-17))]
    [(= index 49)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 1.1352550225747513)
        (stdlib.math.f64-to-bits -0.12685731518763532)
        (stdlib.math.f64-to-bits 0.88085934888181006)
        (stdlib.math.f64-to-bits -9.1054953361102193e-18))]
    [(= index 50)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 1.1302429094831266)
        (stdlib.math.f64-to-bits -0.12243257376712791)
        (stdlib.math.f64-to-bits 0.88476555934096668)
        (stdlib.math.f64-to-bits -3.5124146516207661e-17))]
    [(= index 51)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 1.1252747693068048)
        (stdlib.math.f64-to-bits -0.11802724521862729)
        (stdlib.math.f64-to-bits 0.88867184022620804)
        (stdlib.math.f64-to-bits 3.5552618153740227e-17))]
    [(= index 52)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 1.1203501571039876)
        (stdlib.math.f64-to-bits -0.11364127671663482)
        (stdlib.math.f64-to-bits 0.89257808700176133)
        (stdlib.math.f64-to-bits 1.692380503540994e-17))]
    [(= index 53)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 1.1154683327680124)
        (stdlib.math.f64-to-bits -0.10927434611278386)
        (stdlib.math.f64-to-bits 0.89648443673745537)
        (stdlib.math.f64-to-bits -1.0837881791715702e-17))]
    [(= index 54)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 1.1106291463292157)
        (stdlib.math.f64-to-bits -0.10492665324943573)
        (stdlib.math.f64-to-bits 0.90039056088626834)
        (stdlib.math.f64-to-bits 5.2900545724138363e-17))]
    [(= index 55)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 1.1058315813301596)
        (stdlib.math.f64-to-bits -0.10059761422644442)
        (stdlib.math.f64-to-bits 0.90429683586820775)
        (stdlib.math.f64-to-bits 5.3330721088784517e-17))]
    [(= index 56)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 1.1010752177696026)
        (stdlib.math.f64-to-bits -0.096287173090559008)
        (stdlib.math.f64-to-bits 0.90820316710574411)
        (stdlib.math.f64-to-bits 1.8640040753232978e-17))]
    [(= index 57)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 1.0963597137952512)
        (stdlib.math.f64-to-bits -0.091995340695575578)
        (stdlib.math.f64-to-bits 0.91210939933054969)
        (stdlib.math.f64-to-bits 4.4679728320540751e-17))]
    [(= index 58)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 1.0916844827550398)
        (stdlib.math.f64-to-bits -0.087721900366886985)
        (stdlib.math.f64-to-bits 0.91601558490264567)
        (stdlib.math.f64-to-bits -5.2162134195850327e-18))]
    [(= index 59)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 1.0870487291277784)
        (stdlib.math.f64-to-bits -0.083466436138678546)
        (stdlib.math.f64-to-bits 0.91992196228624989)
        (stdlib.math.f64-to-bits -2.7324731032846873e-17))]
    [(= index 60)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 1.082452357388312)
        (stdlib.math.f64-to-bits -0.079229168275446682)
        (stdlib.math.f64-to-bits 0.9238281880717143)
        (stdlib.math.f64-to-bits -1.7769263393434193e-17))]
    [(= index 61)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 1.0778948225025884)
        (stdlib.math.f64-to-bits -0.075009900475038194)
        (stdlib.math.f64-to-bits 0.92773430127279288)
        (stdlib.math.f64-to-bits 4.9433630808174411e-17))]
    [(= index 62)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 1.0733751731601076)
        (stdlib.math.f64-to-bits -0.070808051333528965)
        (stdlib.math.f64-to-bits 0.93164070215627881)
        (stdlib.math.f64-to-bits 4.164434042024055e-17))]
    [(= index 63)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 1.068893585073351)
        (stdlib.math.f64-to-bits -0.06662408085151128)
        (stdlib.math.f64-to-bits 0.93554682520746602)
        (stdlib.math.f64-to-bits 1.3011820859795741e-17))]
    [(= index 64)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 1.0644491706655506)
        (stdlib.math.f64-to-bits -0.062457454719151428)
        (stdlib.math.f64-to-bits 0.93945303125629431)
        (stdlib.math.f64-to-bits -2.7332907838481398e-17))]
    [(= index 65)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 1.0600414846328305)
        (stdlib.math.f64-to-bits -0.058308043804231602)
        (stdlib.math.f64-to-bits 0.94335930668446688)
        (stdlib.math.f64-to-bits 2.3421331708032919e-17))]
    [(= index 66)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 1.0556701316181605)
        (stdlib.math.f64-to-bits -0.05417576112313327)
        (stdlib.math.f64-to-bits 0.94726559940383293)
        (stdlib.math.f64-to-bits 1.6478717480487438e-17))]
    [(= index 67)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 1.0513347505569259)
        (stdlib.math.f64-to-bits -0.050060547896805474)
        (stdlib.math.f64-to-bits 0.9511718313032721)
        (stdlib.math.f64-to-bits -5.1960829013149901e-18))]
    [(= index 68)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 1.0470347288442157)
        (stdlib.math.f64-to-bits -0.045962101199052086)
        (stdlib.math.f64-to-bits 0.95507815782181782)
        (stdlib.math.f64-to-bits -3.5565573220578997e-17))]
    [(= index 69)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 1.0427699229652954)
        (stdlib.math.f64-to-bits -0.041880560088657148)
        (stdlib.math.f64-to-bits 0.95898431473390433)
        (stdlib.math.f64-to-bits 2.0816772146458738e-17))]
    [(= index 70)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 1.0385395013738175)
        (stdlib.math.f64-to-bits -0.037815400561839851)
        (stdlib.math.f64-to-bits 0.96289067356336855)
        (stdlib.math.f64-to-bits -3.4719628261468409e-18))]
    [(= index 71)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 1.0343434189403451)
        (stdlib.math.f64-to-bits -0.033766847579158821)
        (stdlib.math.f64-to-bits 0.9667968893972092)
        (stdlib.math.f64-to-bits -3.6864683447264197e-17))]
    [(= index 72)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 1.0301811073173315)
        (stdlib.math.f64-to-bits -0.029734619131772888)
        (stdlib.math.f64-to-bits 0.97070310540257787)
        (stdlib.math.f64-to-bits -3.4674108076868834e-18))]
    [(= index 73)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 1.026052043621297)
        (stdlib.math.f64-to-bits -0.025718470239212365)
        (stdlib.math.f64-to-bits 0.97460943254949306)
        (stdlib.math.f64-to-bits 4.5981526247743919e-17))]
    [(= index 74)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 1.0219561082336197)
        (stdlib.math.f64-to-bits -0.021718543925430822)
        (stdlib.math.f64-to-bits 0.97851560545827221)
        (stdlib.math.f64-to-bits 4.5531457523925683e-17))]
    [(= index 75)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 1.0178926505784922)
        (stdlib.math.f64-to-bits -0.017734461269810708)
        (stdlib.math.f64-to-bits 0.98242186878122817)
        (stdlib.math.f64-to-bits -7.8112591694189783e-18))]
    [(= index 76)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 1.0138614436244586)
        (stdlib.math.f64-to-bits -0.013766252464051831)
        (stdlib.math.f64-to-bits 0.98632806907529169)
        (stdlib.math.f64-to-bits 2.0375615178047467e-17))]
    [(= index 77)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 1.0098620186501341)
        (stdlib.math.f64-to-bits -0.0098137063225749444)
        (stdlib.math.f64-to-bits 0.99023429095460336)
        (stdlib.math.f64-to-bits -1.344597043422914e-17))]
    [(= index 78)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 1.0058938559734134)
        (stdlib.math.f64-to-bits -0.005876555150052809)
        (stdlib.math.f64-to-bits 0.99414067802640083)
        (stdlib.math.f64-to-bits 1.5185372369505401e-17))]
    [(= index 79)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 1.0019569623501401)
        (stdlib.math.f64-to-bits -0.0019550499938532084)
        (stdlib.math.f64-to-bits 0.99804685987155584)
        (stdlib.math.f64-to-bits -1.301926039598001e-17))]
    [(= index 80)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 0.99610899230885086)
        (stdlib.math.f64-to-bits 0.0038985973556009412)
        (stdlib.math.f64-to-bits 1.0039062067717412)
        (stdlib.math.f64-to-bits -4.5961206417449733e-17))]
    [(= index 81)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 0.98841703381852009)
        (stdlib.math.f64-to-bits 0.011650571286395461)
        (stdlib.math.f64-to-bits 1.0117187035281372)
        (stdlib.math.f64-to-bits -8.1524050026653492e-17))]
    [(= index 82)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 0.98084291910052968)
        (stdlib.math.f64-to-bits 0.019342955478919066)
        (stdlib.math.f64-to-bits 1.0195312424919558)
        (stdlib.math.f64-to-bits 8.2399270147578115e-17))]
    [(= index 83)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 0.97338401699874455)
        (stdlib.math.f64-to-bits 0.026976601484648199)
        (stdlib.math.f64-to-bits 1.0273437641634193)
        (stdlib.math.f64-to-bits 3.1228510053270453e-17))]
    [(= index 84)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 0.96603775688765559)
        (stdlib.math.f64-to-bits 0.034552359728422744)
        (stdlib.math.f64-to-bits 1.0351562274561221)
        (stdlib.math.f64-to-bits -1.3010212611128995e-17))]
    [(= index 85)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 0.95880149453073693)
        (stdlib.math.f64-to-bits 0.042071217671832528)
        (stdlib.math.f64-to-bits 1.0429687539123276)
        (stdlib.math.f64-to-bits -5.9841166886334577e-17))]
    [(= index 86)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 0.95167285690731107)
        (stdlib.math.f64-to-bits 0.049533940950141186)
        (stdlib.math.f64-to-bits 1.0507812561238108)
        (stdlib.math.f64-to-bits 2.8609238548223351e-17))]
    [(= index 87)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 0.9446494635965822)
        (stdlib.math.f64-to-bits 0.056941358295944156)
        (stdlib.math.f64-to-bits 1.0585937308350133)
        (stdlib.math.f64-to-bits -1.9962944508904598e-17))]
    [(= index 88)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 0.93772889930262227)
        (stdlib.math.f64-to-bits 0.064294391683461072)
        (stdlib.math.f64-to-bits 1.0664062936992642)
        (stdlib.math.f64-to-bits 5.2914691303090992e-17))]
    [(= index 89)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 0.93090910737906807)
        (stdlib.math.f64-to-bits 0.071593635494650698)
        (stdlib.math.f64-to-bits 1.0742187309945372)
        (stdlib.math.f64-to-bits 1.0321575006732523e-16))]
    [(= index 90)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 0.92418768161272202)
        (stdlib.math.f64-to-bits 0.078840109337761533)
        (stdlib.math.f64-to-bits 1.0820313015371339)
        (stdlib.math.f64-to-bits 9.0211943734191189e-17))]
    [(= index 91)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 0.91756267655991919)
        (stdlib.math.f64-to-bits 0.086034389059705063)
        (stdlib.math.f64-to-bits 1.0898438063644336)
        (stdlib.math.f64-to-bits 5.2027989923579528e-17))]
    [(= index 92)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 0.91103204036240337)
        (stdlib.math.f64-to-bits 0.093177211800139048)
        (stdlib.math.f64-to-bits 1.0976562356711468)
        (stdlib.math.f64-to-bits 5.8983184825007853e-17))]
    [(= index 93)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 0.90459358397620238)
        (stdlib.math.f64-to-bits 0.10026951462748457)
        (stdlib.math.f64-to-bits 1.1054688179463226)
        (stdlib.math.f64-to-bits 8.8463776906532518e-17))]
    [(= index 94)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 0.89824563759228249)
        (stdlib.math.f64-to-bits 0.10731170956330516)
        (stdlib.math.f64-to-bits 1.113281220803328)
        (stdlib.math.f64-to-bits -9.5294559652125745e-18))]
    [(= index 95)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 0.89198609667825013)
        (stdlib.math.f64-to-bits 0.11430473320717738)
        (stdlib.math.f64-to-bits 1.1210937073167315)
        (stdlib.math.f64-to-bits 6.7650807093777866e-17))]
    [(= index 96)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 0.88581311211851288)
        (stdlib.math.f64-to-bits 0.12124928503033061)
        (stdlib.math.f64-to-bits 1.1289062967338532)
        (stdlib.math.f64-to-bits 1.0929327370933015e-16))]
    [(= index 97)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 0.87972507576067605)
        (stdlib.math.f64-to-bits 0.12814583422959913)
        (stdlib.math.f64-to-bits 1.1367187631150848)
        (stdlib.math.f64-to-bits 6.9385705512305156e-17))]
    [(= index 98)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 0.87372013726346853)
        (stdlib.math.f64-to-bits 0.13499516368517561)
        (stdlib.math.f64-to-bits 1.1445312490244826)
        (stdlib.math.f64-to-bits 1.908841015045148e-17))]
    [(= index 99)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 0.86779664057822725)
        (stdlib.math.f64-to-bits 0.1417978768189414)
        (stdlib.math.f64-to-bits 1.1523437096203593)
        (stdlib.math.f64-to-bits 2.7744504138979832e-17))]
    [(= index 100)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 0.86195280500607385)
        (stdlib.math.f64-to-bits 0.14855476039031146)
        (stdlib.math.f64-to-bits 1.1601563266482477)
        (stdlib.math.f64-to-bits -1.5621964097491672e-17))]
    [(= index 101)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 0.85618723544206921)
        (stdlib.math.f64-to-bits 0.15526619376589679)
        (stdlib.math.f64-to-bits 1.1679688257483505)
        (stdlib.math.f64-to-bits -6.4191661495975e-17))]
    [(= index 102)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 0.85049839278168926)
        (stdlib.math.f64-to-bits 0.16193275688146969)
        (stdlib.math.f64-to-bits 1.1757811754697645)
        (stdlib.math.f64-to-bits -4.3364651650592681e-17))]
    [(= index 103)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 0.84488445727903039)
        (stdlib.math.f64-to-bits 0.16855539792220497)
        (stdlib.math.f64-to-bits 1.1835937936656129)
        (stdlib.math.f64-to-bits -3.8159292551356396e-17))]
    [(= index 104)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 0.83934427415759649)
        (stdlib.math.f64-to-bits 0.1751343179947753)
        (stdlib.math.f64-to-bits 1.1914062331617676)
        (stdlib.math.f64-to-bits -2.94933042768015e-17))]
    [(= index 105)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 0.83387622493494384)
        (stdlib.math.f64-to-bits 0.1816702989864325)
        (stdlib.math.f64-to-bits 1.1992187450577771)
        (stdlib.math.f64-to-bits -6.2441429163513478e-17))]
    [(= index 106)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 0.82847893205577783)
        (stdlib.math.f64-to-bits 0.18816387146023317)
        (stdlib.math.f64-to-bits 1.2070312971249755)
        (stdlib.math.f64-to-bits 7.4586446226274127e-17))]
    [(= index 107)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 0.82315108000658321)
        (stdlib.math.f64-to-bits 0.1946155228479256)
        (stdlib.math.f64-to-bits 1.2148438169965134)
        (stdlib.math.f64-to-bits 2.7760519266147807e-17))]
    [(= index 108)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 0.81789139037787073)
        (stdlib.math.f64-to-bits 0.20102572579389744)
        (stdlib.math.f64-to-bits 1.2226562252208011)
        (stdlib.math.f64-to-bits -7.0251069210796655e-17))]
    [(= index 109)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 0.81269840072453736)
        (stdlib.math.f64-to-bits 0.20739520907955011)
        (stdlib.math.f64-to-bits 1.2304687681290862)
        (stdlib.math.f64-to-bits 3.7292622364618835e-17))]
    [(= index 110)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 0.80757100294602269)
        (stdlib.math.f64-to-bits 0.21372429840596396)
        (stdlib.math.f64-to-bits 1.2382812116234925)
        (stdlib.math.f64-to-bits 2.2558949940652082e-17))]
    [(= index 111)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 0.80250788811604146)
        (stdlib.math.f64-to-bits 0.22001359459818559)
        (stdlib.math.f64-to-bits 1.2460936706149877)
        (stdlib.math.f64-to-bits 8.4993689444006646e-17))]
    [(= index 112)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 0.79750773793643315)
        (stdlib.math.f64-to-bits 0.22626374162859975)
        (stdlib.math.f64-to-bits 1.2539063289686938)
        (stdlib.math.f64-to-bits 1.039515474644361e-17))]
    [(= index 113)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 0.79256960496637296)
        (stdlib.math.f64-to-bits 0.23247494747693054)
        (stdlib.math.f64-to-bits 1.2617188367227732)
        (stdlib.math.f64-to-bits 3.2972622232754989e-17))]
    [(= index 114)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 0.78769236412541144)
        (stdlib.math.f64-to-bits 0.23864766620658884)
        (stdlib.math.f64-to-bits 1.2695311590462317)
        (stdlib.math.f64-to-bits 4.5098832535941547e-17))]
    [(= index 115)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 0.78287467249409981)
        (stdlib.math.f64-to-bits 0.24478265647405806)
        (stdlib.math.f64-to-bits 1.2773436606579409)
        (stdlib.math.f64-to-bits -7.546987371769545e-17))]
    [(= index 116)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 0.77811553887908114)
        (stdlib.math.f64-to-bits 0.25088025827324145)
        (stdlib.math.f64-to-bits 1.2851561882963496)
        (stdlib.math.f64-to-bits 9.4542955988181837e-17))]
    [(= index 117)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 0.77341395578697769)
        (stdlib.math.f64-to-bits 0.25694085525105947)
        (stdlib.math.f64-to-bits 1.2929686521915196)
        (stdlib.math.f64-to-bits -7.2854560911974897e-17))]
    [(= index 118)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 0.76876871799149327)
        (stdlib.math.f64-to-bits 0.26296511155101143)
        (stdlib.math.f64-to-bits 1.3007813359167737)
        (stdlib.math.f64-to-bits -8.9343576514628023e-17))]
    [(= index 119)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 0.76417906980418537)
        (stdlib.math.f64-to-bits 0.26895313271893428)
        (stdlib.math.f64-to-bits 1.3085938093753886)
        (stdlib.math.f64-to-bits 8.1525705945810205e-17))]
    [(= index 120)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 0.75964387636923991)
        (stdlib.math.f64-to-bits 0.27490553924610595)
        (stdlib.math.f64-to-bits 1.3164063202609564)
        (stdlib.math.f64-to-bits 6.9463414607658815e-18))]
    [(= index 121)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 0.75516219510786675)
        (stdlib.math.f64-to-bits 0.28082272484789428)
        (stdlib.math.f64-to-bits 1.3242188320313901)
        (stdlib.math.f64-to-bits -7.8927313807216758e-17))]
    [(= index 122)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 0.7507331780216866)
        (stdlib.math.f64-to-bits 0.28670497926725602)
        (stdlib.math.f64-to-bits 1.3320311786874468)
        (stdlib.math.f64-to-bits -4.3384657500713545e-17))]
    [(= index 123)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 0.74635571963617509)
        (stdlib.math.f64-to-bits 0.29255295645509705)
        (stdlib.math.f64-to-bits 1.3398436880573092)
        (stdlib.math.f64-to-bits 9.6275779545987923e-17))]
    [(= index 124)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 0.74202893648696533)
        (stdlib.math.f64-to-bits 0.29836703861428759)
        (stdlib.math.f64-to-bits 1.3476563390295309)
        (stdlib.math.f64-to-bits 4.2492400590204517e-17))]
    [(= index 125)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 0.73775215370658764)
        (stdlib.math.f64-to-bits 0.30414734587282055)
        (stdlib.math.f64-to-bits 1.3554687641043626)
        (stdlib.math.f64-to-bits -1.0843419551446047e-16))]
    [(= index 126)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 0.73352429660026075)
        (stdlib.math.f64-to-bits 0.30989455774829366)
        (stdlib.math.f64-to-bits 1.3632813590971713)
        (stdlib.math.f64-to-bits -8.5017278247202501e-17))]
    [(= index 127)
      (MathLogF64TableEntry
        (stdlib.math.f64-to-bits 0.72934477745784099)
        (stdlib.math.f64-to-bits 0.31560871301871884)
        (stdlib.math.f64-to-bits 1.3710936595522603)
        (stdlib.math.f64-to-bits -7.1106272061629222e-17))]
    [else (MathLogF64TableEntry 0 0 0 0)]))

;: Internal binary32 logarithm reduction constants, evaluated as binary64.
(defstruct MathLogF32TableEntry
  (invc-bits u64)
  (logc-bits u64))

;: Return the exact musl binary32 logarithm constants for interval index.
(define (math-log-f32-table-entry [index : i64]) : MathLogF32TableEntry
  (cond
    [(= index 0)
      (MathLogF32TableEntry
        (stdlib.math.f64-to-bits 1.3989071621465281)
        (stdlib.math.f64-to-bits -0.33569133332882284))]
    [(= index 1)
      (MathLogF32TableEntry
        (stdlib.math.f64-to-bits 1.3403141896637998)
        (stdlib.math.f64-to-bits -0.29290405637740741))]
    [(= index 2)
      (MathLogF32TableEntry
        (stdlib.math.f64-to-bits 1.286432210124115)
        (stdlib.math.f64-to-bits -0.25187265809373688))]
    [(= index 3)
      (MathLogF32TableEntry
        (stdlib.math.f64-to-bits 1.2367150214269895)
        (stdlib.math.f64-to-bits -0.21245868807117255))]
    [(= index 4)
      (MathLogF32TableEntry
        (stdlib.math.f64-to-bits 1.1906977166711752)
        (stdlib.math.f64-to-bits -0.17453945183745634))]
    [(= index 5)
      (MathLogF32TableEntry
        (stdlib.math.f64-to-bits 1.1479821020556429)
        (stdlib.math.f64-to-bits -0.1380057072319758))]
    [(= index 6)
      (MathLogF32TableEntry
        (stdlib.math.f64-to-bits 1.1082251448272158)
        (stdlib.math.f64-to-bits -0.10275976698545139))]
    [(= index 7)
      (MathLogF32TableEntry
        (stdlib.math.f64-to-bits 1.0711297413057381)
        (stdlib.math.f64-to-bits -0.068713924470205245))]
    [(= index 8)
      (MathLogF32TableEntry
        (stdlib.math.f64-to-bits 1.0364372789772831)
        (stdlib.math.f64-to-bits -0.035789138739822798))]
    [(= index 9)
      (MathLogF32TableEntry
        (stdlib.math.f64-to-bits 1.0)
        (stdlib.math.f64-to-bits 0.0))]
    [(= index 10)
      (MathLogF32TableEntry
        (stdlib.math.f64-to-bits 0.9492859795739057)
        (stdlib.math.f64-to-bits 0.052045177429294959))]
    [(= index 11)
      (MathLogF32TableEntry
        (stdlib.math.f64-to-bits 0.89510494286090037)
        (stdlib.math.f64-to-bits 0.11081431298787942))]
    [(= index 12)
      (MathLogF32TableEntry
        (stdlib.math.f64-to-bits 0.84768216203511026)
        (stdlib.math.f64-to-bits 0.16524952236951429))]
    [(= index 13)
      (MathLogF32TableEntry
        (stdlib.math.f64-to-bits 0.80503148516920009)
        (stdlib.math.f64-to-bits 0.21687389031699977))]
    [(= index 14)
      (MathLogF32TableEntry
        (stdlib.math.f64-to-bits 0.7664671008843108)
        (stdlib.math.f64-to-bits 0.26596350281213971))]
    [(= index 15)
      (MathLogF32TableEntry
        (stdlib.math.f64-to-bits 0.73142860331632797)
        (stdlib.math.f64-to-bits 0.31275566640735569))]
    [else (MathLogF32TableEntry 0 0)]))

;: Evaluate the compensated binary64 logarithm path for values close to one.
(define (math-log-f64-near-one [value : f64]) : f64
  (let
    [r : f64 (- value 1.0)]
    [r2 : f64 (* r r)]
    [r3 : f64 (* r r2)]
    [y : f64
      (*
        r3
        (+
          (+
            (+
              (stdlib.math.f64-from-bits 0x3fd5555555555577)
              (* r (stdlib.math.f64-from-bits 0xbfcffffffffffdcb)))
            (* r2 (stdlib.math.f64-from-bits 0x3fc999999995dd0c)))
          (*
            r3
            (+
              (+
                (+
                  (stdlib.math.f64-from-bits 0xbfc55555556745a7)
                  (* r (stdlib.math.f64-from-bits 0x3fc24924a344de30)))
                (* r2 (stdlib.math.f64-from-bits 0xbfbfffffa4423d65)))
              (*
                r3
                (+
                  (+
                    (+
                      (stdlib.math.f64-from-bits 0x3fbc7184282ad6ca)
                      (* r (stdlib.math.f64-from-bits 0xbfb999eb43b068ff)))
                    (* r2 (stdlib.math.f64-from-bits 0x3fb78182f7afd085)))
                  (* r3 (stdlib.math.f64-from-bits 0xbfb5521375d145cd))))))))]
    [split : f64 (* r (stdlib.math.f64-from-bits 0x41a0000000000000))]
    [rhi : f64 (- (+ r split) split)]
    [rlo : f64 (- r rhi)]
    [w : f64 (* (* rhi rhi) (stdlib.math.f64-from-bits 0xbfe0000000000000))]
    [hi : f64 (+ r w)]
    [lo : f64 (+ (- r hi) w)]
    (begin
      (set!
        lo
        (+
          lo
          (* (* (stdlib.math.f64-from-bits 0xbfe0000000000000) rlo) (+ rhi r))))
      (set! y (+ y lo))
      (+ y hi))))

;: Evaluate the ordinary binary64 logarithm table reduction.
(define (math-log-f64-finite [bits : u64]) : f64
  (let
    [normalized-bits : u64
      (if (< bits (cast 0x0010000000000000 : u64))
        (-
          (stdlib.math.f64-to-bits
            (*
              (stdlib.math.f64-from-bits bits)
              (stdlib.math.f64-from-bits 0x4330000000000000)))
          (shl (cast 52 : u64) 52))
        bits)]
    [tmp : u64 (- normalized-bits (cast 0x3fe6000000000000 : u64))]
    [index : i64 (cast (bit-and (shr tmp 45) (cast 127 : u64)) : i64)]
    [k : i64 (shr (cast tmp : i64) 52)]
    [reduced-bits : u64
      (- normalized-bits (bit-and tmp (cast 0xfff0000000000000 : u64)))]
    [entry : MathLogF64TableEntry (math-log-f64-table-entry index)]
    [invc : f64 (stdlib.math.f64-from-bits (struct-get entry invc-bits))]
    [logc : f64 (stdlib.math.f64-from-bits (struct-get entry logc-bits))]
    [chi : f64 (stdlib.math.f64-from-bits (struct-get entry chi-bits))]
    [clo : f64 (stdlib.math.f64-from-bits (struct-get entry clo-bits))]
    [z : f64 (stdlib.math.f64-from-bits reduced-bits)]
    [r : f64 (* (- (- z chi) clo) invc)]
    [kd : f64 (cast k : f64)]
    [w : f64 (+ (* kd (stdlib.math.f64-from-bits 0x3fe62e42fefa3800)) logc)]
    [hi : f64 (+ w r)]
    [lo : f64
      (+ (+ (- w hi) r) (* kd (stdlib.math.f64-from-bits 0x3d2ef35793c76730)))]
    [r2 : f64 (* r r)]
    (+
      (+
        (+ lo (* r2 (stdlib.math.f64-from-bits 0xbfe0000000000001)))
        (*
          (* r r2)
          (+
            (+
              (stdlib.math.f64-from-bits 0x3fd555555551305b)
              (* r (stdlib.math.f64-from-bits 0xbfcfffffffeb4590)))
            (*
              r2
              (+
                (stdlib.math.f64-from-bits 0x3fc999b324f10111)
                (* r (stdlib.math.f64-from-bits 0xbfc55575e506c89f)))))))
      hi)))

;: Return the natural logarithm of binary64 value without allocation or
;: platform math calls.
;:
;: The implementation uses musl's 128-way non-FMA table reduction and a
;: compensated near-one polynomial. Under default round-to-nearest its
;: worst-case error is below one ULP. Either signed zero maps to negative
;: infinity, negative finite values and negative infinity map to NaN, one maps
;: to positive zero, positive infinity is unchanged, and NaNs remain NaN.
;: Floating exception flags and signaling-NaN payload behavior are outside the
;: initial contract.
(define (f64-log [value : f64]) : f64
  (let
    [bits : u64 (stdlib.math.f64-to-bits value)]
    [magnitude : u64 (bit-and bits (cast 0x7fffffffffffffff : u64))]
    (cond
      [(= bits (cast 0x3ff0000000000000 : u64)) 0.0]
      [(= magnitude (cast 0 : u64)) (stdlib.math.f64-negative-infinity)]
      [(!= (bit-and bits (cast 0x8000000000000000 : u64)) (cast 0 : u64))
        (stdlib.math.f64-quiet-nan)]
      [(>= magnitude (cast 0x7ff0000000000000 : u64)) value]
      [(and
          (>= bits (cast 0x3fee000000000000 : u64))
          (< bits (cast 0x3ff1090000000000 : u64)))
        (math-log-f64-near-one value)]
      [else (math-log-f64-finite bits)])))

;: Evaluate the positive finite binary32 logarithm table reduction.
(define (math-log-f32-finite [bits : u32]) : f32
  (let
    [normalized-bits : u32
      (if (< bits (cast 0x00800000 : u32))
        (-
          (stdlib.math.f32-to-bits
            (*
              (stdlib.math.f32-from-bits bits)
              (stdlib.math.f32-from-bits (cast 0x4b000000 : u32))))
          (shl (cast 23 : u32) 23))
        bits)]
    [tmp : u32 (- normalized-bits (cast 0x3f330000 : u32))]
    [index : i64 (cast (bit-and (shr tmp 19) (cast 15 : u32)) : i64)]
    [k : i64 (cast (shr (cast tmp : i32) 23) : i64)]
    [reduced-bits : u32
      (- normalized-bits (bit-and tmp (cast 0xff800000 : u32)))]
    [entry : MathLogF32TableEntry (math-log-f32-table-entry index)]
    [invc : f64 (stdlib.math.f64-from-bits (struct-get entry invc-bits))]
    [logc : f64 (stdlib.math.f64-from-bits (struct-get entry logc-bits))]
    [z : f64 (cast (stdlib.math.f32-from-bits reduced-bits) : f64)]
    [r : f64 (- (* z invc) 1.0)]
    [y0 : f64
      (+ logc (* (cast k : f64) (stdlib.math.f64-from-bits 0x3fe62e42fefa39ef)))]
    [r2 : f64 (* r r)]
    [y : f64
      (+
        (* (stdlib.math.f64-from-bits 0x3fd5575b0be00b6a) r)
        (stdlib.math.f64-from-bits 0xbfdffffef20a4123))]
    (begin
      (set! y (+ (* (stdlib.math.f64-from-bits 0xbfd00ea348b88334) r2) y))
      (set! y (+ (* y r2) (+ y0 r)))
      (cast y : f32))))

;: Return the natural logarithm of binary32 value without allocation or
;: platform math calls.
;:
;: The 16-way table reduction evaluates its degree-four polynomial in binary64
;: before one final binary32 rounding. Its round-to-nearest error is below one
;: ULP and special-value behavior matches f64-log.
(define (f32-log [value : f32]) : f32
  (let
    [bits : u32 (stdlib.math.f32-to-bits value)]
    [magnitude : u32 (bit-and bits (cast 0x7fffffff : u32))]
    (cond
      [(= bits (cast 0x3f800000 : u32)) (cast 0.0 : f32)]
      [(= magnitude (cast 0 : u32)) (stdlib.math.f32-negative-infinity)]
      [(!= (bit-and bits (cast 0x80000000 : u32)) (cast 0 : u32))
        (stdlib.math.f32-quiet-nan)]
      [(>= magnitude (cast 0x7f800000 : u32)) value]
      [else (math-log-f32-finite bits)])))

;: Return the natural logarithm for an f64 or f32 expression, preserving its
;: type and evaluating the expression once.
(defmacro (log [value : comptime.Expr]) : comptime.Expr
  (match (type-kind (comptime.expr-type value))
    ["f64" `(stdlib.math.f64-log ,value)]
    ["f32" `(stdlib.math.f32-log ,value)]
    [_
      (comptime.comptime-error
        (comptime.string-append
          "math.log: expected f64 or f32, found "
          (type-kind (comptime.expr-type value))))]))

;; The trigonometric implementation below is derived from the musl/fdlibm
;; sources pinned in MATH_LICENSES.md. Keep the constants as exact IEEE-754
;; bit patterns and preserve the written operation order: the polynomial error
;; bounds and compensated argument reduction depend on both.
;: Internal quadrant and compensated remainder from pi/2 argument reduction.
(defstruct MathTrigReduction
  (quadrant i64)
  (hi f64)
  (lo f64))

;; 1,584 binary digits (396 hexadecimal digits) of 2/pi, split into 24-bit
;; limbs. Binary64 needs at most limb 46 for its largest finite exponent; the
;; complete 66-limb fdlibm double table is retained so reducer recomputation
;; always has headroom. A lookup function keeps the constants in code instead
;; of creating a heap-allocated module-global array during startup.
;: Return one exact 24-bit limb of the internal 2/pi reduction table.
(define (math-trig-two-over-pi-limb [index : i64]) : u32
  (cond
    [(= index 0) 0xA2F983]
    [(= index 1) 0x6E4E44]
    [(= index 2) 0x1529FC]
    [(= index 3) 0x2757D1]
    [(= index 4) 0xF534DD]
    [(= index 5) 0xC0DB62]
    [(= index 6) 0x95993C]
    [(= index 7) 0x439041]
    [(= index 8) 0xFE5163]
    [(= index 9) 0xABDEBB]
    [(= index 10) 0xC561B7]
    [(= index 11) 0x246E3A]
    [(= index 12) 0x424DD2]
    [(= index 13) 0xE00649]
    [(= index 14) 0x2EEA09]
    [(= index 15) 0xD1921C]
    [(= index 16) 0xFE1DEB]
    [(= index 17) 0x1CB129]
    [(= index 18) 0xA73EE8]
    [(= index 19) 0x8235F5]
    [(= index 20) 0x2EBB44]
    [(= index 21) 0x84E99C]
    [(= index 22) 0x7026B4]
    [(= index 23) 0x5F7E41]
    [(= index 24) 0x3991D6]
    [(= index 25) 0x398353]
    [(= index 26) 0x39F49C]
    [(= index 27) 0x845F8B]
    [(= index 28) 0xBDF928]
    [(= index 29) 0x3B1FF8]
    [(= index 30) 0x97FFDE]
    [(= index 31) 0x05980F]
    [(= index 32) 0xEF2F11]
    [(= index 33) 0x8B5A0A]
    [(= index 34) 0x6D1F6D]
    [(= index 35) 0x367ECF]
    [(= index 36) 0x27CB09]
    [(= index 37) 0xB74F46]
    [(= index 38) 0x3F669E]
    [(= index 39) 0x5FEA2D]
    [(= index 40) 0x7527BA]
    [(= index 41) 0xC7EBE5]
    [(= index 42) 0xF17B3D]
    [(= index 43) 0x0739F7]
    [(= index 44) 0x8A5292]
    [(= index 45) 0xEA6BFB]
    [(= index 46) 0x5FB11F]
    [(= index 47) 0x8D5D08]
    [(= index 48) 0x560330]
    [(= index 49) 0x46FC7B]
    [(= index 50) 0x6BABF0]
    [(= index 51) 0xCFBC20]
    [(= index 52) 0x9AF436]
    [(= index 53) 0x1DA9E3]
    [(= index 54) 0x91615E]
    [(= index 55) 0xE61B08]
    [(= index 56) 0x659985]
    [(= index 57) 0x5F14A0]
    [(= index 58) 0x68408D]
    [(= index 59) 0xFFD880]
    [(= index 60) 0x4D7327]
    [(= index 61) 0x310606]
    [(= index 62) 0x1556CA]
    [(= index 63) 0x73A8C9]
    [(= index 64) 0x60E27B]
    [(= index 65) 0xC08C6B]
    [else 0]))

;; pi/2 split into non-overlapping 24-bit pieces. As above, the lookup avoids
;; startup allocation for a global fixed array.
;: Return one exact non-overlapping piece of the internal pi/2 table.
(define (math-trig-pi-over-two-piece [index : i64]) : f64
  (cond
    [(= index 0) (stdlib.math.f64-from-bits 0x3FF921FB40000000)]
    [(= index 1) (stdlib.math.f64-from-bits 0x3E74442D00000000)]
    [(= index 2) (stdlib.math.f64-from-bits 0x3CF8469880000000)]
    [(= index 3) (stdlib.math.f64-from-bits 0x3B78CC5160000000)]
    [(= index 4) (stdlib.math.f64-from-bits 0x39F01B8380000000)]
    [(= index 5) (stdlib.math.f64-from-bits 0x387A252040000000)]
    [(= index 6) (stdlib.math.f64-from-bits 0x36E3822280000000)]
    [else (stdlib.math.f64-from-bits 0x3569F31D00000000)]))

;: Return one limb from the decomposed reducer input.
(define (math-trig-input-limb [index : i64] [x0 : f64] [x1 : f64] [x2 : f64]) : f64
  (if (= index 0)
    x0
    (if (= index 1)
      x1
      x2)))

;; Payne-Hanek-style reduction from musl __rem_pio2_large.c. The input is a
;; positive significand split into one (binary32) or three (binary64) 24-bit
;; limbs. Only precisions 0 (one-term float remainder) and 1 (two-term double
;; remainder) are needed here.
;: Reduce a positive, limb-decomposed input by pi/2 across the full exponent range.
(define (math-trig-rem-pio2-large
  [x0 : f64]
  [x1 : f64]
  [x2 : f64]
  [e0 : i64]
  [nx : i64]
  [precision : i64]) : MathTrigReduction
  (let
    [iq : (Array i64 20) (init)]
    [f : (Array f64 20) (init)]
    [fq : (Array f64 20) (init)]
    [q : (Array f64 20) (init)]
    [jk : i64
      (if (= precision 0)
        3
        4)]
    [jp : i64 jk]
    [jx : i64 (- nx 1)]
    [jv : i64 (/ (- e0 3) 24)]
    [q0 : i64 0]
    [jz : i64 0]
    [carry : i64 0]
    [n : i64 0]
    [ih : i64 0]
    [i : i64 0]
    [j : i64 0]
    [k : i64 0]
    [m : i64 0]
    [z : f64 0.0]
    [fw : f64 0.0]
    [need-recompute : bool true]
    (begin
      (if (< jv 0)
        (set! jv 0)
        unit)
      (set! q0 (- e0 (* 24 (+ jv 1))))
      ;; f[0..jx+jk] selects the exponent-local window of the 2/pi table.
      (set! j (- jv jx))
      (set! m (+ jx jk))
      (set! i 0)
      (while (<= i m)
        (begin
          (array-set!
            f
            i
            (if (< j 0)
              0.0
              (cast (math-trig-two-over-pi-limb j) : f64)))
          (set! i (+ i 1))
          (set! j (+ j 1))))
      ;; q is the local convolution of the significand and 2/pi limbs.
      (set! i 0)
      (while (<= i jk)
        (begin
          (set! fw 0.0)
          (set! j 0)
          (while (<= j jx)
            (begin
              (set!
                fw
                (+
                  fw
                  (*
                    (math-trig-input-limb j x0 x1 x2)
                    (array-ref f (- (+ jx i) j)))))
              (set! j (+ j 1))))
          (array-set! q i fw)
          (set! i (+ i 1))))
      (set! jz jk)
      (while need-recompute
        (begin
          ;; Distill q into base-2^24 integer limbs in reverse order.
          (set! i 0)
          (set! j jz)
          (set! z (array-ref q jz))
          (while (> j 0)
            (begin
              (set!
                fw
                (cast (cast (* 0.000000059604644775390625 z) : i64) : f64))
              (array-set! iq i (cast (- z (* 16777216.0 fw)) : i64))
              (set! z (+ (array-ref q (- j 1)) fw))
              (set! i (+ i 1))
              (set! j (- j 1))))
          ;; Extract N mod 8 and the fractional product.
          (set! z (stdlib.math.f64-scalbn z q0))
          (set! z (- z (* 8.0 (cast (cast (* z 0.125) : i64) : f64))))
          (set! n (cast z : i64))
          (set! z (- z (cast n : f64)))
          (set! ih 0)
          (cond
            [(> q0 0)
              (begin
                (set! i (shr (array-ref iq (- jz 1)) (- 24 q0)))
                (set! n (+ n i))
                (array-set!
                  iq
                  (- jz 1)
                  (- (array-ref iq (- jz 1)) (shl i (- 24 q0))))
                (set! ih (shr (array-ref iq (- jz 1)) (- 23 q0))))]
            [(= q0 0) (set! ih (shr (array-ref iq (- jz 1)) 23))]
            [(>= z 0.5) (set! ih 2)]
            [else unit])
          ;; Fold q > 1/2 to 1-q and remember the remainder sign.
          (if (> ih 0)
            (begin
              (set! n (+ n 1))
              (set! carry 0)
              (set! i 0)
              (while (< i jz)
                (begin
                  (set! j (array-ref iq i))
                  (if (= carry 0)
                    (if (!= j 0)
                      (begin
                        (set! carry 1)
                        (array-set! iq i (- 0x1000000 j)))
                      unit)
                    (array-set! iq i (- 0xffffff j)))
                  (set! i (+ i 1))))
              (if (= q0 1)
                (array-set!
                  iq
                  (- jz 1)
                  (bit-and (array-ref iq (- jz 1)) 0x7fffff))
                (if (= q0 2)
                  (array-set!
                    iq
                    (- jz 1)
                    (bit-and (array-ref iq (- jz 1)) 0x3fffff))
                  unit))
              (if (= ih 2)
                (begin
                  (set! z (- 1.0 z))
                  (if (!= carry 0)
                    (set! z (- z (stdlib.math.f64-scalbn 1.0 q0)))
                    unit))
                unit))
            unit)
          ;; Exact cancellation can consume the current table window. Extend
          ;; the convolution just far enough and distill it again.
          (set! need-recompute false)
          (if (= z 0.0)
            (begin
              (set! j 0)
              (set! i (- jz 1))
              (while (>= i jk)
                (begin
                  (set! j (bit-or j (array-ref iq i)))
                  (set! i (- i 1))))
              (if (= j 0)
                (begin
                  (set! k 1)
                  (while (= (array-ref iq (- jk k)) 0)
                    (set! k (+ k 1)))
                  (set! i (+ jz 1))
                  (while (<= i (+ jz k))
                    (begin
                      (array-set!
                        f
                        (+ jx i)
                        (cast (math-trig-two-over-pi-limb (+ jv i)) : f64))
                      (set! fw 0.0)
                      (set! j 0)
                      (while (<= j jx)
                        (begin
                          (set!
                            fw
                            (+
                              fw
                              (*
                                (math-trig-input-limb j x0 x1 x2)
                                (array-ref f (- (+ jx i) j)))))
                          (set! j (+ j 1))))
                      (array-set! q i fw)
                      (set! i (+ i 1))))
                  (set! jz (+ jz k))
                  (set! need-recompute true))
                unit))
            unit)))
      ;; Normalize the final fractional limbs.
      (if (= z 0.0)
        (begin
          (set! jz (- jz 1))
          (set! q0 (- q0 24))
          (while (= (array-ref iq jz) 0)
            (begin
              (set! jz (- jz 1))
              (set! q0 (- q0 24)))))
        (begin
          (set! z (stdlib.math.f64-scalbn z (- 0 q0)))
          (if (>= z 16777216.0)
            (begin
              (set!
                fw
                (cast (cast (* 0.000000059604644775390625 z) : i64) : f64))
              (array-set! iq jz (cast (- z (* 16777216.0 fw)) : i64))
              (set! jz (+ jz 1))
              (set! q0 (+ q0 24))
              (array-set! iq jz (cast fw : i64)))
            (array-set! iq jz (cast z : i64)))))
      ;; Convert integer limbs back to scaled floating values.
      (set! fw (stdlib.math.f64-scalbn 1.0 q0))
      (set! i jz)
      (while (>= i 0)
        (begin
          (array-set! q i (* fw (cast (array-ref iq i) : f64)))
          (set! fw (* fw 0.000000059604644775390625))
          (set! i (- i 1))))
      ;; Multiply by the split pi/2 table.
      (set! i jz)
      (while (>= i 0)
        (begin
          (set! fw 0.0)
          (set! k 0)
          (while (and (<= k jp) (<= k (- jz i)))
            (begin
              (set!
                fw
                (+ fw (* (math-trig-pi-over-two-piece k) (array-ref q (+ i k)))))
              (set! k (+ k 1))))
          (array-set! fq (- jz i) fw)
          (set! i (- i 1))))
      ;; Compress to one term for binary32 or a compensated two-term result
      ;; for binary64.
      (set! fw 0.0)
      (set! i jz)
      (while (>= i 0)
        (begin
          (set! fw (+ fw (array-ref fq i)))
          (set! i (- i 1))))
      (if (= precision 0)
        (MathTrigReduction
          (bit-and n 7)
          (if (= ih 0)
            fw
            (- 0.0 fw))
          0.0)
        (let
          [head : f64 fw]
          [tail : f64 (- (array-ref fq 0) fw)]
          (begin
            (set! i 1)
            (while (<= i jz)
              (begin
                (set! tail (+ tail (array-ref fq i)))
                (set! i (+ i 1))))
            (MathTrigReduction
              (bit-and n 7)
              (if (= ih 0)
                head
                (- 0.0 head))
              (if (= ih 0)
                tail
                (- 0.0 tail)))))))))

;: Construct an internal binary64 constant from its exact IEEE-754 bits.
(define (math-trig-f64-constant [bits : u64]) : f64
  (stdlib.math.f64-from-bits bits))

;: Clear the low binary64 word for compensated tangent arithmetic.
(define (math-trig-truncate-low-word [value : f64]) : f64
  (stdlib.math.f64-from-bits
    (bit-and (stdlib.math.f64-to-bits value) (cast 0xffffffff00000000 : u64))))

;; Binary64 pi/2 reduction. The medium path uses three compensated 33-bit
;; pieces; the large path decomposes the significand into 24-bit limbs for the
;; shared Payne-Hanek reducer above.
;: Reduce any binary64 input to a compensated remainder modulo pi/2.
(define (math-trig-rem-pio2-f64 [value : f64]) : MathTrigReduction
  (let
    [bits : u64 (stdlib.math.f64-to-bits value)]
    [ix : u64 (bit-and (shr bits 32) (cast 0x7fffffff : u64))]
    [fn : f64 0.0]
    [n : i64 0]
    [r : f64 0.0]
    [w : f64 0.0]
    [t : f64 0.0]
    [hi : f64 0.0]
    [ex : i64 0]
    [ey : i64 0]
    (if (< ix (cast 0x413921fb : u64))
      (begin
        ;; rint(value * 2/pi) for round-to-nearest without an extern.
        (set!
          fn
          (+
            (* value (math-trig-f64-constant (cast 0x3FE45F306DC9C883 : u64)))
            (math-trig-f64-constant (cast 0x4338000000000000 : u64))))
        (set!
          fn
          (- fn (math-trig-f64-constant (cast 0x4338000000000000 : u64))))
        (set! n (cast fn : i64))
        (set!
          r
          (-
            value
            (* fn (math-trig-f64-constant (cast 0x3FF921FB54400000 : u64)))))
        (set! w (* fn (math-trig-f64-constant (cast 0x3DD0B4611A626331 : u64))))
        (if (<
          (- r w)
          (- 0.0 (math-trig-f64-constant (cast 0x3FE921FB54442D18 : u64))))
          (begin
            (set! n (- n 1))
            (set! fn (- fn 1.0))
            (set!
              r
              (-
                value
                (* fn (math-trig-f64-constant (cast 0x3FF921FB54400000 : u64)))))
            (set!
              w
              (* fn (math-trig-f64-constant (cast 0x3DD0B4611A626331 : u64)))))
          (if (>
            (- r w)
            (math-trig-f64-constant (cast 0x3FE921FB54442D18 : u64)))
            (begin
              (set! n (+ n 1))
              (set! fn (+ fn 1.0))
              (set!
                r
                (-
                  value
                  (*
                    fn
                    (math-trig-f64-constant (cast 0x3FF921FB54400000 : u64)))))
              (set!
                w
                (* fn (math-trig-f64-constant (cast 0x3DD0B4611A626331 : u64)))))
            unit))
        (set! hi (- r w))
        (set! ex (cast (shr ix 20) : i64))
        (set!
          ey
          (cast
            (bit-and (shr (stdlib.math.f64-to-bits hi) 52) (cast 0x7ff : u64))
            : i64))
        (if (> (- ex ey) 16)
          (begin
            (set! t r)
            (set!
              w
              (* fn (math-trig-f64-constant (cast 0x3DD0B4611A600000 : u64))))
            (set! r (- t w))
            (set!
              w
              (-
                (* fn (math-trig-f64-constant (cast 0x3BA3198A2E037073 : u64)))
                (- (- t r) w)))
            (set! hi (- r w))
            (set!
              ey
              (cast
                (bit-and
                  (shr (stdlib.math.f64-to-bits hi) 52)
                  (cast 0x7ff : u64))
                : i64))
            (if (> (- ex ey) 49)
              (begin
                (set! t r)
                (set!
                  w
                  (*
                    fn
                    (math-trig-f64-constant (cast 0x3BA3198A2E000000 : u64))))
                (set! r (- t w))
                (set!
                  w
                  (-
                    (*
                      fn
                      (math-trig-f64-constant (cast 0x397B839A252049C1 : u64)))
                    (- (- t r) w)))
                (set! hi (- r w)))
              unit))
          unit)
        (MathTrigReduction n hi (- (- r hi) w)))
      (if (>= ix (cast 0x7ff00000 : u64))
        (let
          [nan : f64 (- value value)]
          (MathTrigReduction 0 nan nan))
        (let
          [magnitude : u64 (bit-and bits (cast 0x000fffffffffffff : u64))]
          [normalized : u64 (bit-or magnitude (cast 0x4160000000000000 : u64))]
          [z : f64 (stdlib.math.f64-from-bits normalized)]
          [x0 : f64 0.0]
          [x1 : f64 0.0]
          [x2 : f64 0.0]
          [nx : i64 3]
          [large : MathTrigReduction (MathTrigReduction 0 0.0 0.0)]
          (begin
            (set! x0 (cast (cast z : i64) : f64))
            (set! z (* (- z x0) 16777216.0))
            (set! x1 (cast (cast z : i64) : f64))
            (set! z (* (- z x1) 16777216.0))
            (set! x2 z)
            (if (= x2 0.0)
              (begin
                (set! nx 2)
                (if (= x1 0.0)
                  (set! nx 1)
                  unit))
              unit)
            (set!
              large
              (math-trig-rem-pio2-large
                x0
                x1
                x2
                (- (cast (shr ix 20) : i64) (+ 0x3ff 23))
                nx
                1))
            (if (!=
              (bit-and bits (cast 0x8000000000000000 : u64))
              (cast 0 : u64))
              (MathTrigReduction
                (- 0 (struct-get large quadrant))
                (- 0.0 (struct-get large hi))
                (- 0.0 (struct-get large lo)))
              large)))))))

;; Binary32 reduction keeps all arithmetic in binary64, then returns the
;; one-term remainder expected by the float kernels.
;: Reduce any binary32 input to a binary64 remainder modulo pi/2.
(define (math-trig-rem-pio2-f32 [value : f32]) : MathTrigReduction
  (let
    [bits : u32 (stdlib.math.f32-to-bits value)]
    [ix : u32 (bit-and bits (cast 0x7fffffff : u32))]
    [wide : f64 (cast value : f64)]
    [fn : f64 0.0]
    [n : i64 0]
    [remainder : f64 0.0]
    (if (< ix (cast 0x4dc90fdb : u32))
      (begin
        (set!
          fn
          (+
            (* wide (math-trig-f64-constant (cast 0x3FE45F306DC9C883 : u64)))
            (math-trig-f64-constant (cast 0x4338000000000000 : u64))))
        (set!
          fn
          (- fn (math-trig-f64-constant (cast 0x4338000000000000 : u64))))
        (set! n (cast fn : i64))
        (set!
          remainder
          (-
            (-
              wide
              (* fn (math-trig-f64-constant (cast 0x3FF921FB50000000 : u64))))
            (* fn (math-trig-f64-constant (cast 0x3E5110B4611A6263 : u64)))))
        (if (<
          remainder
          (- 0.0 (math-trig-f64-constant (cast 0x3FE921FB60000000 : u64))))
          (begin
            (set! n (- n 1))
            (set! fn (- fn 1.0))
            (set!
              remainder
              (-
                (-
                  wide
                  (*
                    fn
                    (math-trig-f64-constant (cast 0x3FF921FB50000000 : u64))))
                (* fn (math-trig-f64-constant (cast 0x3E5110B4611A6263 : u64))))))
          (if (>
            remainder
            (math-trig-f64-constant (cast 0x3FE921FB60000000 : u64)))
            (begin
              (set! n (+ n 1))
              (set! fn (+ fn 1.0))
              (set!
                remainder
                (-
                  (-
                    wide
                    (*
                      fn
                      (math-trig-f64-constant (cast 0x3FF921FB50000000 : u64))))
                  (*
                    fn
                    (math-trig-f64-constant (cast 0x3E5110B4611A6263 : u64))))))
            unit))
        (MathTrigReduction n remainder 0.0))
      (if (>= ix (cast 0x7f800000 : u32))
        (let
          [nan : f64 (- wide wide)]
          (MathTrigReduction 0 nan 0.0))
        (let
          [sign : bool
            (!= (bit-and bits (cast 0x80000000 : u32)) (cast 0 : u32))]
          [e0 : i64 (- (cast (shr ix 23) : i64) (+ 0x7f 23))]
          [scaled-bits : u32 (- ix (shl (cast e0 : u32) 23))]
          [large : MathTrigReduction
            (math-trig-rem-pio2-large
              (cast (stdlib.math.f32-from-bits scaled-bits) : f64)
              0.0
              0.0
              e0
              1
              0)]
          (if sign
            (MathTrigReduction
              (- 0 (struct-get large quadrant))
              (- 0.0 (struct-get large hi))
              0.0)
            large))))))

;; Polynomial kernels on the reduced interval [-pi/4, pi/4].
;: Evaluate the internal binary64 sine kernel on the reduced interval.
(define (math-trig-kernel-sin-f64 [x : f64] [tail : f64] [tail-present : bool]) : f64
  (let
    [z : f64 (* x x)]
    [w : f64 (* z z)]
    [r : f64
      (+
        (math-trig-f64-constant (cast 0x3F8111111110F8A6 : u64))
        (*
          z
          (+
            (math-trig-f64-constant (cast 0xBF2A01A019C161D5 : u64))
            (* z (math-trig-f64-constant (cast 0x3EC71DE357B1FE7D : u64)))))
        (*
          z
          w
          (+
            (math-trig-f64-constant (cast 0xBE5AE5E68A2B9CEB : u64))
            (* z (math-trig-f64-constant (cast 0x3DE5D93A5ACFD57C : u64))))))]
    [v : f64 (* z x)]
    (if tail-present
      (-
        x
        (-
          (- (* z (- (* 0.5 tail) (* v r))) tail)
          (* v (math-trig-f64-constant (cast 0xBFC5555555555549 : u64)))))
      (+
        x
        (*
          v
          (+ (math-trig-f64-constant (cast 0xBFC5555555555549 : u64)) (* z r)))))))

;: Evaluate the internal binary64 cosine kernel on the reduced interval.
(define (math-trig-kernel-cos-f64 [x : f64] [tail : f64]) : f64
  (let
    [z : f64 (* x x)]
    [w : f64 (* z z)]
    [r : f64
      (+
        (*
          z
          (+
            (math-trig-f64-constant (cast 0x3FA555555555554C : u64))
            (*
              z
              (+
                (math-trig-f64-constant (cast 0xBF56C16C16C15177 : u64))
                (* z (math-trig-f64-constant (cast 0x3EFA01A019CB1590 : u64)))))))
        (*
          w
          w
          (+
            (math-trig-f64-constant (cast 0xBE927E4F809C52AD : u64))
            (*
              z
              (+
                (math-trig-f64-constant (cast 0x3E21EE9EBDB4B1C4 : u64))
                (* z (math-trig-f64-constant (cast 0xBDA8FAE9BE8838D4 : u64))))))))]
    [half-z : f64 (* 0.5 z)]
    [base : f64 (- 1.0 half-z)]
    (+ base (+ (- (- 1.0 base) half-z) (- (* z r) (* x tail))))))

;: Evaluate tangent or negative cotangent on the reduced binary64 interval.
(define (math-trig-kernel-tan-f64
  [input-x : f64]
  [input-tail : f64]
  [odd : bool]) : f64
  (let
    [x : f64 input-x]
    [tail : f64 input-tail]
    [high : u64
      (bit-and (shr (stdlib.math.f64-to-bits x) 32) (cast 0x7fffffff : u64))]
    [big : bool (>= high (cast 0x3FE59428 : u64))]
    [negative : bool (stdlib.math.f64-sign-bit? x)]
    [z : f64 0.0]
    [w : f64 0.0]
    [r : f64 0.0]
    [v : f64 0.0]
    [s : f64 0.0]
    (begin
      (if big
        (begin
          (if negative
            (begin
              (set! x (- 0.0 x))
              (set! tail (- 0.0 tail)))
            unit)
          (set!
            x
            (+
              (- (math-trig-f64-constant (cast 0x3FE921FB54442D18 : u64)) x)
              (- (math-trig-f64-constant (cast 0x3C81A62633145C07 : u64)) tail)))
          (set! tail 0.0))
        unit)
      (set! z (* x x))
      (set! w (* z z))
      (set!
        r
        (+
          (math-trig-f64-constant (cast 0x3FC111111110FE7A : u64))
          (*
            w
            (+
              (math-trig-f64-constant (cast 0x3F9664F48406D637 : u64))
              (*
                w
                (+
                  (math-trig-f64-constant (cast 0x3F6D6D22C9560328 : u64))
                  (*
                    w
                    (+
                      (math-trig-f64-constant (cast 0x3F4344D8F2F26501 : u64))
                      (*
                        w
                        (+
                          (math-trig-f64-constant
                            (cast 0x3F147E88A03792A6 : u64))
                          (*
                            w
                            (math-trig-f64-constant
                              (cast 0xBEF375CBDB605373 : u64)))))))))))))
      (set!
        v
        (*
          z
          (+
            (math-trig-f64-constant (cast 0x3FABA1BA1BB341FE : u64))
            (*
              w
              (+
                (math-trig-f64-constant (cast 0x3F8226E3E96E8493 : u64))
                (*
                  w
                  (+
                    (math-trig-f64-constant (cast 0x3F57DBC8FEE08315 : u64))
                    (*
                      w
                      (+
                        (math-trig-f64-constant (cast 0x3F3026F71A8D1068 : u64))
                        (*
                          w
                          (+
                            (math-trig-f64-constant
                              (cast 0x3F12B80F32F0A7E9 : u64))
                            (*
                              w
                              (math-trig-f64-constant
                                (cast 0x3EFB2A7074BF7AD4 : u64))))))))))))))
      (set! s (* z x))
      (set!
        r
        (+
          tail
          (* z (+ (* s (+ r v)) tail))
          (* s (math-trig-f64-constant (cast 0x3FD5555555555563 : u64)))))
      (set! w (+ x r))
      (if big
        (let
          [sign : f64
            (if odd
              -1.0
              1.0)]
          [result : f64 (- sign (* 2.0 (+ x (- r (/ (* w w) (+ w sign))))))]
          (if negative
            (- 0.0 result)
            result))
        (if (not odd)
          w
          (let
            [w0 : f64 (math-trig-truncate-low-word w)]
            [correction : f64 (- r (- w0 x))]
            [reciprocal : f64 (/ -1.0 w)]
            [a0 : f64 (math-trig-truncate-low-word reciprocal)]
            (+ a0 (* reciprocal (+ 1.0 (+ (* a0 w0) (* a0 correction)))))))))))

;: Evaluate the internal binary32 sine kernel on the reduced interval.
(define (math-trig-kernel-sin-f32 [x : f64]) : f32
  (let
    [z : f64 (* x x)]
    [w : f64 (* z z)]
    [r : f64
      (+
        (math-trig-f64-constant (cast 0xBF2A00F9E2CAE774 : u64))
        (* z (math-trig-f64-constant (cast 0x3EC6CD878C3B46A7 : u64))))]
    [s : f64 (* z x)]
    (cast
      (+
        (+
          x
          (*
            s
            (+
              (math-trig-f64-constant (cast 0xBFC5555554CBAC77 : u64))
              (* z (math-trig-f64-constant (cast 0x3F811110896EFBB2 : u64))))))
        (* s w r))
      : f32)))

;: Evaluate the internal binary32 cosine kernel on the reduced interval.
(define (math-trig-kernel-cos-f32 [x : f64]) : f32
  (let
    [z : f64 (* x x)]
    [w : f64 (* z z)]
    [r : f64
      (+
        (math-trig-f64-constant (cast 0xBF56C087E80F1E27 : u64))
        (* z (math-trig-f64-constant (cast 0x3EF99342E0EE5069 : u64))))]
    (cast
      (+
        (+
          (+ 1.0 (* z (math-trig-f64-constant (cast 0xBFDFFFFFFD0C5E81 : u64))))
          (* w (math-trig-f64-constant (cast 0x3FA55553E1053A42 : u64))))
        (* (* w z) r))
      : f32)))

;: Evaluate tangent or negative cotangent on the reduced binary32 interval.
(define (math-trig-kernel-tan-f32 [x : f64] [odd : bool]) : f32
  (let
    [z : f64 (* x x)]
    [r : f64
      (+
        (math-trig-f64-constant (cast 0x3F685DADFCECF44E : u64))
        (* z (math-trig-f64-constant (cast 0x3F8362B9BF971BCD : u64))))]
    [t : f64
      (+
        (math-trig-f64-constant (cast 0x3FAB54C91D865AFE : u64))
        (* z (math-trig-f64-constant (cast 0x3F991DF3908C33CE : u64))))]
    [w : f64 (* z z)]
    [s : f64 (* z x)]
    [u : f64
      (+
        (math-trig-f64-constant (cast 0x3FD5554D3418C99F : u64))
        (* z (math-trig-f64-constant (cast 0x3FC112FD38999F72 : u64))))]
    [result : f64 (+ (+ x (* s u)) (* (* s w) (+ t (* w r))))]
    (cast
      (if odd
        (/ -1.0 result)
        result)
      : f32)))

;: Return sin(value) for every finite binary64 input.
;:
;: This allocation-free, extern-free implementation follows musl/fdlibm and
;: has a maximum error below 1.5 ULP in round-to-nearest mode.
(define (f64-sin [value : f64]) : f64
  (let
    [ix : u64
      (bit-and (shr (stdlib.math.f64-to-bits value) 32) (cast 0x7fffffff : u64))]
    (if (<= ix (cast 0x3fe921fb : u64))
      (if (< ix (cast 0x3e500000 : u64))
        value
        (math-trig-kernel-sin-f64 value 0.0 false))
      (if (>= ix (cast 0x7ff00000 : u64))
        (- value value)
        (let
          [reduced : MathTrigReduction (math-trig-rem-pio2-f64 value)]
          [quadrant : i64 (bit-and (struct-get reduced quadrant) 3)]
          (cond
            [(= quadrant 0)
              (math-trig-kernel-sin-f64
                (struct-get reduced hi)
                (struct-get reduced lo)
                true)]
            [(= quadrant 1)
              (math-trig-kernel-cos-f64
                (struct-get reduced hi)
                (struct-get reduced lo))]
            [(= quadrant 2)
              (-
                0.0
                (math-trig-kernel-sin-f64
                  (struct-get reduced hi)
                  (struct-get reduced lo)
                  true))]
            [else
              (-
                0.0
                (math-trig-kernel-cos-f64
                  (struct-get reduced hi)
                  (struct-get reduced lo)))]))))))

;: Return cos(value) for every finite binary64 input.
;:
;: The result is nearly rounded with a maximum error below 1.5 ULP in the
;: default round-to-nearest mode.
(define (f64-cos [value : f64]) : f64
  (let
    [ix : u64
      (bit-and (shr (stdlib.math.f64-to-bits value) 32) (cast 0x7fffffff : u64))]
    (if (<= ix (cast 0x3fe921fb : u64))
      (if (< ix (cast 0x3e46a09e : u64))
        1.0
        (math-trig-kernel-cos-f64 value 0.0))
      (if (>= ix (cast 0x7ff00000 : u64))
        (- value value)
        (let
          [reduced : MathTrigReduction (math-trig-rem-pio2-f64 value)]
          [quadrant : i64 (bit-and (struct-get reduced quadrant) 3)]
          (cond
            [(= quadrant 0)
              (math-trig-kernel-cos-f64
                (struct-get reduced hi)
                (struct-get reduced lo))]
            [(= quadrant 1)
              (-
                0.0
                (math-trig-kernel-sin-f64
                  (struct-get reduced hi)
                  (struct-get reduced lo)
                  true))]
            [(= quadrant 2)
              (-
                0.0
                (math-trig-kernel-cos-f64
                  (struct-get reduced hi)
                  (struct-get reduced lo)))]
            [else
              (math-trig-kernel-sin-f64
                (struct-get reduced hi)
                (struct-get reduced lo)
                true)]))))))

;: Return tan(value) for every finite binary64 input.
;:
;: The result is nearly rounded with a maximum error below 1.5 ULP in the
;: default round-to-nearest mode.
(define (f64-tan [value : f64]) : f64
  (let
    [ix : u64
      (bit-and (shr (stdlib.math.f64-to-bits value) 32) (cast 0x7fffffff : u64))]
    (if (<= ix (cast 0x3fe921fb : u64))
      (if (< ix (cast 0x3e400000 : u64))
        value
        (math-trig-kernel-tan-f64 value 0.0 false))
      (if (>= ix (cast 0x7ff00000 : u64))
        (- value value)
        (let
          [reduced : MathTrigReduction (math-trig-rem-pio2-f64 value)]
          (math-trig-kernel-tan-f64
            (struct-get reduced hi)
            (struct-get reduced lo)
            (!= (bit-and (struct-get reduced quadrant) 1) 0)))))))

;: Return sin(value) for every finite binary32 input.
;:
;: Reduction and kernels follow musl/fdlibm and stay below 1.5 ULP in the
;: default round-to-nearest mode.
(define (f32-sin [value : f32]) : f32
  (let
    [ix : u32 (bit-and (stdlib.math.f32-to-bits value) (cast 0x7fffffff : u32))]
    (if (<= ix (cast 0x3f490fda : u32))
      (if (< ix (cast 0x39800000 : u32))
        value
        (math-trig-kernel-sin-f32 (cast value : f64)))
      (if (>= ix (cast 0x7f800000 : u32))
        (- value value)
        (let
          [reduced : MathTrigReduction (math-trig-rem-pio2-f32 value)]
          [quadrant : i64 (bit-and (struct-get reduced quadrant) 3)]
          (cond
            [(= quadrant 0) (math-trig-kernel-sin-f32 (struct-get reduced hi))]
            [(= quadrant 1) (math-trig-kernel-cos-f32 (struct-get reduced hi))]
            [(= quadrant 2)
              (math-trig-kernel-sin-f32 (- 0.0 (struct-get reduced hi)))]
            [else
              (-
                (cast 0.0 : f32)
                (math-trig-kernel-cos-f32 (struct-get reduced hi)))]))))))

;: Return cos(value) for every finite binary32 input.
;:
;: The result is nearly rounded with a maximum error below 1.5 ULP in the
;: default round-to-nearest mode.
(define (f32-cos [value : f32]) : f32
  (let
    [ix : u32 (bit-and (stdlib.math.f32-to-bits value) (cast 0x7fffffff : u32))]
    (if (<= ix (cast 0x3f490fda : u32))
      (if (< ix (cast 0x39800000 : u32))
        (cast 1.0 : f32)
        (math-trig-kernel-cos-f32 (cast value : f64)))
      (if (>= ix (cast 0x7f800000 : u32))
        (- value value)
        (let
          [reduced : MathTrigReduction (math-trig-rem-pio2-f32 value)]
          [quadrant : i64 (bit-and (struct-get reduced quadrant) 3)]
          (cond
            [(= quadrant 0) (math-trig-kernel-cos-f32 (struct-get reduced hi))]
            [(= quadrant 1)
              (math-trig-kernel-sin-f32 (- 0.0 (struct-get reduced hi)))]
            [(= quadrant 2)
              (-
                (cast 0.0 : f32)
                (math-trig-kernel-cos-f32 (struct-get reduced hi)))]
            [else (math-trig-kernel-sin-f32 (struct-get reduced hi))]))))))

;: Return tan(value) for every finite binary32 input.
;:
;: The result is nearly rounded with a maximum error below 1.5 ULP in the
;: default round-to-nearest mode.
(define (f32-tan [value : f32]) : f32
  (let
    [ix : u32 (bit-and (stdlib.math.f32-to-bits value) (cast 0x7fffffff : u32))]
    (if (<= ix (cast 0x3f490fda : u32))
      (if (< ix (cast 0x39800000 : u32))
        value
        (math-trig-kernel-tan-f32 (cast value : f64) false))
      (if (>= ix (cast 0x7f800000 : u32))
        (- value value)
        (let
          [reduced : MathTrigReduction (math-trig-rem-pio2-f32 value)]
          (math-trig-kernel-tan-f32
            (struct-get reduced hi)
            (!= (bit-and (struct-get reduced quadrant) 1) 0)))))))

;: Return the absolute value of an `i64`.
;:
;: The positive magnitude of the most-negative `i64` is not representable, so
;: that value is returned unchanged. Use `i64-abs-or` to choose a fallback.
(define (i64-abs [value : i64]) : i64
  (stdlib.math.i64-abs-or value value))

;: Return the absolute value of an `i64`, or `fallback` for the most-negative
;: `i64` whose positive magnitude is not representable.
(define (i64-abs-or [value : i64] [fallback : i64]) : i64
  (if (= value -9223372036854775808)
    fallback
    (if (< value 0)
      (- 0 value)
      value)))

;: Return the absolute value of an `f64` or `f32` expression.
;:
;: The expression is evaluated once and then checked by ordinary float
;: arithmetic rules.
(defmacro (abs [value : Expr]) : Expr
  `(let
    [__math_abs_value ,value]
    (if (< __math_abs_value 0.0)
      (- 0.0 __math_abs_value)
      __math_abs_value)))

;: Return the smaller `i64` value.
(define (i64-min [a : i64] [b : i64]) : i64
  (if (< a b)
    a
    b))

;: Return the larger `i64` value.
(define (i64-max [a : i64] [b : i64]) : i64
  (if (> a b)
    a
    b))

;: Clamp `value` to the inclusive `i64` range bounded by `a` and `b`.
;:
;: Bounds may be supplied in either order; the helper normalizes them before
;: clamping.
(define (i64-clamp [value : i64] [a : i64] [b : i64]) : i64
  (let
    [lo : i64 (stdlib.math.i64-min a b)]
    [hi : i64 (stdlib.math.i64-max a b)]
    (if (< value lo)
      lo
      (if (> value hi)
        hi
        value))))

;: True when `value` is less than zero.
(define (i64-negative? [value : i64]) : bool
  (< value 0))

;: True when `value` is equal to zero.
(define (i64-zero? [value : i64]) : bool
  (= value 0))

;: True when `value` is greater than zero.
(define (i64-positive? [value : i64]) : bool
  (> value 0))

;: Return the absolute value of an `f64`.
(define (f64-abs [value : f64]) : f64
  (stdlib.math.f64-from-bits
    (bit-and (stdlib.math.f64-to-bits value) 0x7fffffffffffffff)))

;: Return the absolute value of an `f32`.
(define (f32-abs [value : f32]) : f32
  (stdlib.math.f32-from-bits
    (bit-and (stdlib.math.f32-to-bits value) (cast 0x7fffffff : u32))))

;: Return the scalar SSE2 square root of an `f64`.
;:
;: Under the default MXCSR round-to-nearest, ties-to-even mode, positive finite
;: normal and subnormal inputs are correctly rounded. Positive and negative
;: zero retain their sign, positive infinity is unchanged, negative finite
;: values and negative infinity produce NaN, and NaN inputs produce NaN.
;: Signaling-NaN payload, quieting, and floating-point exception details follow
;: the hardware and are not part of this public contract.
(define (f64-sqrt [value : f64]) : f64
  (__tl_float_sqrt value))

;: Return the scalar SSE2 square root of an `f32`.
;:
;: Behavior matches `f64-sqrt` at binary32 precision and follows the active
;: MXCSR rounding mode.
(define (f32-sqrt [value : f32]) : f32
  (__tl_float_sqrt value))

;: Return the square root of an `f64` or `f32` expression, preserving its type.
;:
;: The expression is evaluated exactly once. Other operand types are rejected
;: with a compile-time diagnostic.
(defmacro (sqrt [value : comptime.Expr]) : comptime.Expr
  (match (type-kind (comptime.expr-type value))
    ["f64" `(stdlib.math.f64-sqrt ,value)]
    ["f32" `(stdlib.math.f32-sqrt ,value)]
    [_
      (comptime.comptime-error
        (comptime.string-append
          "math.sqrt: expected f64 or f32, found "
          (type-kind (comptime.expr-type value))))]))

;: Return the smaller `f64` value according to TypeLisp scalar comparison.
(define (f64-min [a : f64] [b : f64]) : f64
  (if (< a b)
    a
    b))

;: Return the larger `f64` value according to TypeLisp scalar comparison.
(define (f64-max [a : f64] [b : f64]) : f64
  (if (> a b)
    a
    b))

;: Clamp `value` to the inclusive `f64` range bounded by `a` and `b`.
;:
;: Bounds may be supplied in either order; the helper normalizes them before
;: clamping.
(define (f64-clamp [value : f64] [a : f64] [b : f64]) : f64
  (let
    [lo : f64 (stdlib.math.f64-min a b)]
    [hi : f64 (stdlib.math.f64-max a b)]
    (if (< value lo)
      lo
      (if (> value hi)
        hi
        value))))

;: True when `value` is less than zero.
(define (f64-negative? [value : f64]) : bool
  (< value 0.0))

;: True when `value` is equal to zero.
(define (f64-zero? [value : f64]) : bool
  (= value 0.0))

;: True when `value` is greater than zero.
(define (f64-positive? [value : f64]) : bool
  (> value 0.0))

(test
  math-trig-reduction-and-special-values
  (let
    [fail : (-> unit)
      (lambda () : unit
        (begin
          (/ 1 0)
          unit))]
    [pi : f64 (stdlib.math.f64-from-bits 0x400921fb54442d18)]
    [max64 : f64 (stdlib.math.f64-from-bits 0x7fefffffffffffff)]
    [max32 : f32 (stdlib.math.f32-from-bits (cast 0x7f7fffff : u32))]
    [medium : MathTrigReduction (stdlib.math.math-trig-rem-pio2-f64 pi)]
    [large64 : MathTrigReduction (stdlib.math.math-trig-rem-pio2-f64 max64)]
    [large32 : MathTrigReduction (stdlib.math.math-trig-rem-pio2-f32 max32)]
    [negative-zero64 : f64
      (stdlib.math.f64-from-bits (cast 0x8000000000000000 : u64))]
    [negative-zero32 : f32 (stdlib.math.f32-from-bits (cast 0x80000000 : u32))]
    (begin
      (if (and
        (= (bit-and (struct-get medium quadrant) 3) 2)
        (<= (stdlib.math.f64-abs (struct-get medium hi)) 0.785398164)
        (<= (stdlib.math.f64-abs (struct-get medium lo)) 0.000000000000001)
        (<= (stdlib.math.f64-abs (struct-get large64 hi)) 0.785398164)
        (stdlib.math.f64-finite? (struct-get large64 hi))
        (stdlib.math.f64-finite? (struct-get large64 lo))
        (<= (stdlib.math.f64-abs (struct-get large32 hi)) 0.785398164)
        (stdlib.math.f64-finite? (struct-get large32 hi)))
        unit
        (fail))
      (if (=
        (stdlib.math.f64-to-bits (stdlib.math.f64-sin pi))
        (cast 0x3ca1a62633145c07 : u64))
        unit
        (fail))
      (if (= (stdlib.math.f64-cos pi) -1.0)
        unit
        (fail))
      (if (=
        (stdlib.math.f64-to-bits (stdlib.math.f64-sin negative-zero64))
        (cast 0x8000000000000000 : u64))
        unit
        (fail))
      (if (=
        (stdlib.math.f64-to-bits (stdlib.math.f64-tan negative-zero64))
        (cast 0x8000000000000000 : u64))
        unit
        (fail))
      (if (=
        (stdlib.math.f32-to-bits (stdlib.math.f32-sin negative-zero32))
        (cast 0x80000000 : u32))
        unit
        (fail))
      (if (=
        (stdlib.math.f32-to-bits (stdlib.math.f32-tan negative-zero32))
        (cast 0x80000000 : u32))
        unit
        (fail))
      (if (and
        (stdlib.math.f64-nan?
          (stdlib.math.f64-sin (stdlib.math.f64-positive-infinity)))
        (stdlib.math.f64-nan?
          (stdlib.math.f64-cos (stdlib.math.f64-negative-infinity)))
        (stdlib.math.f64-nan? (stdlib.math.f64-tan (stdlib.math.f64-quiet-nan)))
        (stdlib.math.f32-nan?
          (stdlib.math.f32-sin (stdlib.math.f32-positive-infinity)))
        (stdlib.math.f32-nan?
          (stdlib.math.f32-cos (stdlib.math.f32-negative-infinity)))
        (stdlib.math.f32-nan? (stdlib.math.f32-tan (stdlib.math.f32-quiet-nan))))
        unit
        (fail)))))

(test
  math-i64-api
  (let
    [fail : (-> unit)
      (lambda () : unit
        (begin
          (/ 1 0)
          unit))]
    (begin
      (if (= (stdlib.math.i64-abs -7) 7)
        unit
        (fail))
      (if (= (stdlib.math.i64-abs 0) 0)
        unit
        (fail))
      (if (= (stdlib.math.i64-abs 7) 7)
        unit
        (fail))
      (if (= (stdlib.math.i64-abs -9223372036854775808) -9223372036854775808)
        unit
        (fail))
      (if (=
        (stdlib.math.i64-abs-or -9223372036854775808 9223372036854775807)
        9223372036854775807)
        unit
        (fail))
      (if (= (stdlib.math.i64-min -3 9) -3)
        unit
        (fail))
      (if (= (stdlib.math.i64-max -3 9) 9)
        unit
        (fail))
      (if (= (stdlib.math.i64-clamp 5 0 10) 5)
        unit
        (fail))
      (if (= (stdlib.math.i64-clamp -1 0 10) 0)
        unit
        (fail))
      (if (= (stdlib.math.i64-clamp 11 0 10) 10)
        unit
        (fail))
      (if (= (stdlib.math.i64-clamp -1 10 0) 0)
        unit
        (fail))
      (if (= (stdlib.math.i64-clamp 11 10 0) 10)
        unit
        (fail))
      (if (stdlib.math.i64-negative? -1)
        unit
        (fail))
      (if (stdlib.math.i64-zero? 0)
        unit
        (fail))
      (if (stdlib.math.i64-positive? 1)
        unit
        (fail))
      (if (not (stdlib.math.i64-positive? 0))
        unit
        (fail)))))

(test
  math-f64-api
  (let
    [fail : (-> unit)
      (lambda () : unit
        (begin
          (/ 1 0)
          unit))]
    [abs-neg : f64 -2.5]
    [abs-want : f64 2.5]
    (begin
      (if (= (stdlib.math.f64-abs -2.5) 2.5)
        unit
        (fail))
      (if (= (stdlib.math.f64-abs 0.0) 0.0)
        unit
        (fail))
      (if (= (stdlib.math.f64-abs 2.5) 2.5)
        unit
        (fail))
      (if (= (stdlib.math.abs abs-neg) abs-want)
        unit
        (fail))
      (if (= (stdlib.math.f64-min -3.5 9.25) -3.5)
        unit
        (fail))
      (if (= (stdlib.math.f64-max -3.5 9.25) 9.25)
        unit
        (fail))
      (if (= (stdlib.math.f64-clamp 5.5 0.0 10.0) 5.5)
        unit
        (fail))
      (if (= (stdlib.math.f64-clamp -1.0 0.0 10.0) 0.0)
        unit
        (fail))
      (if (= (stdlib.math.f64-clamp 11.0 0.0 10.0) 10.0)
        unit
        (fail))
      (if (= (stdlib.math.f64-clamp 11.0 10.0 0.0) 10.0)
        unit
        (fail))
      (if (stdlib.math.f64-negative? -0.5)
        unit
        (fail))
      (if (stdlib.math.f64-zero? 0.0)
        unit
        (fail))
      (if (stdlib.math.f64-positive? 0.5)
        unit
        (fail))
      (if (not (stdlib.math.f64-negative? 0.0))
        unit
        (fail)))))

(test
  math-f32-api
  (let
    [fail : (-> unit)
      (lambda () : unit
        (begin
          (/ 1 0)
          unit))]
    [neg : f32 -2.5]
    [zero : f32 0.0]
    [pos : f32 2.5]
    [want : f32 2.5]
    (begin
      (if (= (stdlib.math.f32-abs neg) want)
        unit
        (fail))
      (if (= (stdlib.math.f32-abs zero) zero)
        unit
        (fail))
      (if (= (stdlib.math.f32-abs pos) want)
        unit
        (fail))
      (if (= (stdlib.math.abs neg) want)
        unit
        (fail)))))

(test
  math-float-sqrt
  (let
    [fail : (-> unit)
      (lambda () : unit
        (begin
          (/ 1 0)
          unit))]
    [one32 : f32 1.0]
    [four32 : f32 4.0]
    [calls : i64 0]
    [once : f64
      (stdlib.math.sqrt
        (begin
          (set! calls (+ calls 1))
          16.0))]
    [sqrt32 : f32 (stdlib.math.sqrt four32)]
    [negative-zero64 : f64
      (stdlib.math.f64-from-bits (cast 0x8000000000000000 : u64))]
    [negative-zero32 : f32 (stdlib.math.f32-from-bits (cast 0x80000000 : u32))]
    [nan64 : f64 (stdlib.math.f64-from-bits (cast 0x7ff8000000001234 : u64))]
    [nan32 : f32 (stdlib.math.f32-from-bits (cast 0x7fc01234 : u32))]
    (begin
      (if (and
        (= calls 1)
        (= once 4.0)
        (= sqrt32 (stdlib.math.f32-sqrt four32))
        (= (stdlib.math.f64-sqrt 81.0) 9.0)
        (= (stdlib.math.f32-sqrt one32) one32))
        unit
        (fail))
      (if (=
        (stdlib.math.f64-to-bits (stdlib.math.f64-sqrt 2.0))
        (cast 0x3ff6a09e667f3bcd : u64))
        unit
        (fail))
      (if (=
        (stdlib.math.f64-to-bits (stdlib.math.f64-sqrt 3.0))
        (cast 0x3ffbb67ae8584caa : u64))
        unit
        (fail))
      (if (=
        (stdlib.math.f64-to-bits (stdlib.math.f64-sqrt 10.0))
        (cast 0x40094c583ada5b53 : u64))
        unit
        (fail))
      (if (=
        (stdlib.math.f64-to-bits
          (stdlib.math.f64-sqrt
            (stdlib.math.f64-from-bits (cast 0x3fb999999999999a : u64))))
        (cast 0x3fd43d136248490f : u64))
        unit
        (fail))
      (if (=
        (stdlib.math.f64-to-bits
          (stdlib.math.f64-sqrt (stdlib.math.f64-from-bits (cast 1 : u64))))
        (cast 0x1e60000000000000 : u64))
        unit
        (fail))
      (if (=
        (stdlib.math.f64-to-bits
          (stdlib.math.f64-sqrt
            (stdlib.math.f64-from-bits (cast 0x000fffffffffffff : u64))))
        (cast 0x1fffffffffffffff : u64))
        unit
        (fail))
      (if (=
        (stdlib.math.f64-to-bits
          (stdlib.math.f64-sqrt
            (stdlib.math.f64-from-bits (cast 0x0010000000000000 : u64))))
        (cast 0x2000000000000000 : u64))
        unit
        (fail))
      (if (=
        (stdlib.math.f64-to-bits
          (stdlib.math.f64-sqrt
            (stdlib.math.f64-from-bits (cast 0x7fefffffffffffff : u64))))
        (cast 0x5fefffffffffffff : u64))
        unit
        (fail))
      (if (=
        (stdlib.math.f32-to-bits
          (stdlib.math.f32-sqrt
            (stdlib.math.f32-from-bits (cast 0x40000000 : u32))))
        (cast 0x3fb504f3 : u32))
        unit
        (fail))
      (if (=
        (stdlib.math.f32-to-bits
          (stdlib.math.f32-sqrt
            (stdlib.math.f32-from-bits (cast 0x40400000 : u32))))
        (cast 0x3fddb3d7 : u32))
        unit
        (fail))
      (if (=
        (stdlib.math.f32-to-bits
          (stdlib.math.f32-sqrt
            (stdlib.math.f32-from-bits (cast 0x41200000 : u32))))
        (cast 0x404a62c2 : u32))
        unit
        (fail))
      (if (=
        (stdlib.math.f32-to-bits
          (stdlib.math.f32-sqrt
            (stdlib.math.f32-from-bits (cast 0x3dcccccd : u32))))
        (cast 0x3ea1e89b : u32))
        unit
        (fail))
      (if (=
        (stdlib.math.f32-to-bits
          (stdlib.math.f32-sqrt (stdlib.math.f32-from-bits (cast 1 : u32))))
        (cast 0x1a3504f3 : u32))
        unit
        (fail))
      (if (=
        (stdlib.math.f32-to-bits
          (stdlib.math.f32-sqrt
            (stdlib.math.f32-from-bits (cast 0x007fffff : u32))))
        (cast 0x1fffffff : u32))
        unit
        (fail))
      (if (=
        (stdlib.math.f32-to-bits
          (stdlib.math.f32-sqrt
            (stdlib.math.f32-from-bits (cast 0x00800000 : u32))))
        (cast 0x20000000 : u32))
        unit
        (fail))
      (if (=
        (stdlib.math.f32-to-bits
          (stdlib.math.f32-sqrt
            (stdlib.math.f32-from-bits (cast 0x7f7fffff : u32))))
        (cast 0x5f7fffff : u32))
        unit
        (fail))
      (if (and
        (=
          (stdlib.math.f64-to-bits
            (stdlib.math.f64-sqrt (stdlib.math.f64-from-bits (cast 0 : u64))))
          (cast 0 : u64))
        (=
          (stdlib.math.f64-to-bits (stdlib.math.f64-sqrt negative-zero64))
          (cast 0x8000000000000000 : u64))
        (=
          (stdlib.math.f32-to-bits (stdlib.math.f32-sqrt negative-zero32))
          (cast 0x80000000 : u32))
        (stdlib.math.f64-infinite?
          (stdlib.math.f64-sqrt (stdlib.math.f64-positive-infinity)))
        (stdlib.math.f32-infinite?
          (stdlib.math.f32-sqrt (stdlib.math.f32-positive-infinity))))
        unit
        (fail))
      (if (and
        (stdlib.math.f64-nan? (stdlib.math.f64-sqrt -1.0))
        (stdlib.math.f64-nan?
          (stdlib.math.f64-sqrt (stdlib.math.f64-negative-infinity)))
        (stdlib.math.f64-nan? (stdlib.math.f64-sqrt nan64))
        (stdlib.math.f32-nan?
          (stdlib.math.f32-sqrt (stdlib.math.f32-negative-infinity)))
        (stdlib.math.f32-nan? (stdlib.math.f32-sqrt nan32)))
        unit
        (fail)))))

(test
  math-float-exp
  (let
    [fail : (-> unit)
      (lambda () : unit
        (begin
          (/ 1 0)
          unit))]
    [calls : i64 0]
    [once : f64
      (stdlib.math.exp
        (begin
          (set! calls (+ calls 1))
          1.0))]
    [one32 : f32 1.0]
    [exp32 : f32 (stdlib.math.exp one32)]
    (if (and
      (= calls 1)
      (= (stdlib.math.f64-to-bits once) (cast 0x4005bf0a8b145769 : u64))
      (= (stdlib.math.f32-to-bits exp32) (cast 0x402df854 : u32))
      (=
        (stdlib.math.f64-to-bits (stdlib.math.f64-exp -0.0))
        (cast 0x3ff0000000000000 : u64))
      (=
        (stdlib.math.f32-to-bits
          (stdlib.math.f32-exp
            (stdlib.math.f32-from-bits (cast 0x80000000 : u32))))
        (cast 0x3f800000 : u32)))
      unit
      (fail))))

(test
  math-float-log
  (let
    [fail : (-> unit)
      (lambda () : unit
        (begin
          (/ 1 0)
          unit))]
    [calls : i64 0]
    [once : f64
      (stdlib.math.log
        (begin
          (set! calls (+ calls 1))
          2.0))]
    [two32 : f32 2.0]
    [log32 : f32 (stdlib.math.log two32)]
    [negative-zero64 : f64
      (stdlib.math.f64-from-bits (cast 0x8000000000000000 : u64))]
    (if (and
      (= calls 1)
      (= (stdlib.math.f64-to-bits once) (cast 0x3fe62e42fefa39ef : u64))
      (= (stdlib.math.f32-to-bits log32) (cast 0x3f317218 : u32))
      (= (stdlib.math.f64-to-bits (stdlib.math.f64-log 1.0)) (cast 0 : u64))
      (=
        (stdlib.math.f64-to-bits (stdlib.math.f64-log negative-zero64))
        (cast 0xfff0000000000000 : u64))
      (stdlib.math.f64-infinite?
        (stdlib.math.f64-log (stdlib.math.f64-positive-infinity)))
      (stdlib.math.f64-nan? (stdlib.math.f64-log -1.0)))
      unit
      (fail))))

(test
  math-f64-ieee-foundation
  (let
    [fail : (-> unit)
      (lambda () : unit
        (begin
          (/ 1 0)
          unit))]
    [positive-zero : f64 (stdlib.math.f64-from-bits (cast 0 : u64))]
    [negative-zero : f64
      (stdlib.math.f64-from-bits (cast 0x8000000000000000 : u64))]
    [min-subnormal : f64 (stdlib.math.f64-from-bits (cast 1 : u64))]
    [max-subnormal : f64
      (stdlib.math.f64-from-bits (cast 0x000fffffffffffff : u64))]
    [min-normal : f64
      (stdlib.math.f64-from-bits (cast 0x0010000000000000 : u64))]
    [max-finite : f64
      (stdlib.math.f64-from-bits (cast 0x7fefffffffffffff : u64))]
    [payload-nan : f64
      (stdlib.math.f64-from-bits (cast 0x7ff8000000001234 : u64))]
    (begin
      (if (= (stdlib.math.f64-to-bits positive-zero) (cast 0 : u64))
        unit
        (fail))
      (if (=
        (stdlib.math.f64-to-bits negative-zero)
        (cast 0x8000000000000000 : u64))
        unit
        (fail))
      (if (=
        (stdlib.math.f64-to-bits max-subnormal)
        (cast 0x000fffffffffffff : u64))
        unit
        (fail))
      (if (=
        (stdlib.math.f64-to-bits min-normal)
        (cast 0x0010000000000000 : u64))
        unit
        (fail))
      (if (=
        (stdlib.math.f64-to-bits max-finite)
        (cast 0x7fefffffffffffff : u64))
        unit
        (fail))
      (if (=
        (stdlib.math.f64-to-bits payload-nan)
        (cast 0x7ff8000000001234 : u64))
        unit
        (fail))
      (if (and
        (stdlib.math.f64-positive-zero? positive-zero)
        (stdlib.math.f64-negative-zero? negative-zero)
        (stdlib.math.f64-signed-zero? negative-zero)
        (stdlib.math.f64-sign-bit? negative-zero)
        (not (stdlib.math.f64-sign-bit? positive-zero)))
        unit
        (fail))
      (if (and
        (stdlib.math.f64-subnormal? min-subnormal)
        (stdlib.math.f64-subnormal? max-subnormal)
        (stdlib.math.f64-normal? min-normal)
        (stdlib.math.f64-finite? max-finite)
        (stdlib.math.f64-infinite? (stdlib.math.f64-positive-infinity))
        (stdlib.math.f64-infinite? (stdlib.math.f64-negative-infinity))
        (stdlib.math.f64-nan? payload-nan))
        unit
        (fail))
      (if (=
        (stdlib.math.f64-to-bits (stdlib.math.f64-copy-sign 3.0 negative-zero))
        (cast 0xc008000000000000 : u64))
        unit
        (fail))
      (if (= (stdlib.math.f64-to-bits (stdlib.math.f64-abs negative-zero)) 0)
        unit
        (fail))
      (if (= (stdlib.math.f64-scalbn 1.5 3) 12.0)
        unit
        (fail))
      (if (=
        (stdlib.math.f64-to-bits (stdlib.math.f64-scalbn min-normal -1))
        (cast 0x0008000000000000 : u64))
        unit
        (fail))
      (if (=
        (stdlib.math.f64-to-bits (stdlib.math.f64-scalbn 1.0 -1074))
        (cast 1 : u64))
        unit
        (fail))
      (if (=
        (stdlib.math.f64-to-bits (stdlib.math.f64-scalbn 1.0 -1075))
        (cast 0 : u64))
        unit
        (fail))
      (if (=
        (stdlib.math.f64-to-bits (stdlib.math.f64-scalbn 3.0 -1075))
        (cast 2 : u64))
        unit
        (fail))
      (if (=
        (stdlib.math.f64-to-bits (stdlib.math.f64-scalbn -1.0 -1075))
        (cast 0x8000000000000000 : u64))
        unit
        (fail))
      (if (stdlib.math.f64-infinite? (stdlib.math.f64-scalbn max-finite 1))
        unit
        (fail))
      (if (=
        (stdlib.math.f64-to-bits
          (stdlib.math.f64-scalbn (stdlib.math.f64-positive-infinity) -99))
        (cast 0x7ff0000000000000 : u64))
        unit
        (fail))
      (if (stdlib.math.f64-nan? (stdlib.math.f64-scalbn payload-nan 99))
        unit
        (fail)))))

(test
  math-f32-ieee-foundation
  (let
    [fail : (-> unit)
      (lambda () : unit
        (begin
          (/ 1 0)
          unit))]
    [positive-zero : f32 (stdlib.math.f32-from-bits (cast 0 : u32))]
    [negative-zero : f32 (stdlib.math.f32-from-bits (cast 0x80000000 : u32))]
    [min-subnormal : f32 (stdlib.math.f32-from-bits (cast 1 : u32))]
    [max-subnormal : f32 (stdlib.math.f32-from-bits (cast 0x007fffff : u32))]
    [min-normal : f32 (stdlib.math.f32-from-bits (cast 0x00800000 : u32))]
    [max-finite : f32 (stdlib.math.f32-from-bits (cast 0x7f7fffff : u32))]
    [payload-nan : f32 (stdlib.math.f32-from-bits (cast 0x7fc01234 : u32))]
    [one : f32 1.0]
    [three : f32 3.0]
    (begin
      (if (= (stdlib.math.f32-to-bits negative-zero) (cast 0x80000000 : u32))
        unit
        (fail))
      (if (= (stdlib.math.f32-to-bits max-subnormal) (cast 0x007fffff : u32))
        unit
        (fail))
      (if (= (stdlib.math.f32-to-bits min-normal) (cast 0x00800000 : u32))
        unit
        (fail))
      (if (= (stdlib.math.f32-to-bits max-finite) (cast 0x7f7fffff : u32))
        unit
        (fail))
      (if (= (stdlib.math.f32-to-bits payload-nan) (cast 0x7fc01234 : u32))
        unit
        (fail))
      (if (and
        (stdlib.math.f32-positive-zero? positive-zero)
        (stdlib.math.f32-negative-zero? negative-zero)
        (stdlib.math.f32-sign-bit? negative-zero)
        (stdlib.math.f32-subnormal? min-subnormal)
        (stdlib.math.f32-subnormal? max-subnormal)
        (stdlib.math.f32-normal? min-normal)
        (stdlib.math.f32-finite? max-finite)
        (stdlib.math.f32-infinite? (stdlib.math.f32-positive-infinity))
        (stdlib.math.f32-nan? payload-nan))
        unit
        (fail))
      (if (= (stdlib.math.f32-to-bits (stdlib.math.f32-abs negative-zero)) 0)
        unit
        (fail))
      (if (=
        (stdlib.math.f32-to-bits (stdlib.math.f32-scalbn min-normal -1))
        (cast 0x00400000 : u32))
        unit
        (fail))
      (if (=
        (stdlib.math.f32-to-bits (stdlib.math.f32-scalbn one -149))
        (cast 1 : u32))
        unit
        (fail))
      (if (=
        (stdlib.math.f32-to-bits (stdlib.math.f32-scalbn one -150))
        (cast 0 : u32))
        unit
        (fail))
      (if (=
        (stdlib.math.f32-to-bits (stdlib.math.f32-scalbn three -150))
        (cast 2 : u32))
        unit
        (fail))
      (if (=
        (stdlib.math.f32-to-bits (stdlib.math.f32-scalbn negative-zero 1000))
        (cast 0x80000000 : u32))
        unit
        (fail))
      (if (stdlib.math.f32-infinite? (stdlib.math.f32-scalbn max-finite 1))
        unit
        (fail))
      (if (stdlib.math.f32-nan? (stdlib.math.f32-scalbn payload-nan 99))
        unit
        (fail)))))