;# Pure scalar math helpers.
;#
;# This module provides runtime-zero-dependency helpers for scalar integer and
;# IEEE-754 float values. Float bit reinterpretation uses private compiler
;# intrinsics when `feature-compiler-float-bitcast-intrinsics` is available.
;# The inactive compatibility branches keep published stage0 compilers able to
;# build a compiler that introduces those intrinsics.
;# Square root lowers through the private compiler float-sqrt intrinsic to
;# scalar SSE2 on both supported targets.
;#
;# Transcendental functions are added as freestanding implementations in
;# separate slices so Linux and Windows behavior cannot accidentally diverge.
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
  (cfg
    feature-compiler-float-bitcast-intrinsics
    (__tl_float_to_bits value)
    (let
      [buf : (Array f64) (make-array f64 1)]
      (begin
        (array-set! buf 0 value)
        (unsafe
          (ptr-read (ptr-cast (array-data buf) : (Ptr u64))))))))

;: Reinterpret IEEE-754 binary64 `bits` as an `f64`.
(define (f64-from-bits [bits : u64]) : f64
  (cfg
    feature-compiler-float-bitcast-intrinsics
    (__tl_float_from_bits bits)
    (let
      [buf : (Array u64) (make-array u64 1)]
      (begin
        (array-set! buf 0 bits)
        (unsafe
          (ptr-read (ptr-cast (array-data buf) : (Ptr f64))))))))

;: Reinterpret an `f32` as its exact IEEE-754 binary32 bits.
(define (f32-to-bits [value : f32]) : u32
  (cfg
    feature-compiler-float-bitcast-intrinsics
    (__tl_float_to_bits value)
    (let
      [buf : (Array f32) (make-array f32 1)]
      (begin
        (array-set! buf 0 value)
        (unsafe
          (ptr-read (ptr-cast (array-data buf) : (Ptr u32))))))))

;: Reinterpret IEEE-754 binary32 `bits` as an `f32`.
(define (f32-from-bits [bits : u32]) : f32
  (cfg
    feature-compiler-float-bitcast-intrinsics
    (__tl_float_from_bits bits)
    (let
      [buf : (Array u32) (make-array u32 1)]
      (begin
        (array-set! buf 0 bits)
        (unsafe
          (ptr-read (ptr-cast (array-data buf) : (Ptr f32))))))))

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
;; Constants remain exact IEEE-754 bit patterns and operation order is
;; intentionally fixed: both are part of the stated error bounds.
;: Internal exact tail and adjusted scale bits for one binary64 table entry.
(defstruct MathExpF64TableEntry
  (tail-bits u64)
  (scale-bits u64))

;: Return {tail, adjusted 2^(index/128)} bits from musl exp_data.c.
;:
;: Keeping the table in code avoids a heap-allocated module global. Binary32
;: reuses every fourth scale entry, exactly matching musl's exp2f table.
(define (math-exp-f64-table-entry [index : i64]) : MathExpF64TableEntry
  (cond
    [(= index 0) (MathExpF64TableEntry 0x0000000000000000 0x3ff0000000000000)]
    [(= index 1) (MathExpF64TableEntry 0x3c9b3b4f1a88bf6e 0x3feff63da9fb3335)]
    [(= index 2) (MathExpF64TableEntry 0xbc7160139cd8dc5d 0x3fefec9a3e778061)]
    [(= index 3) (MathExpF64TableEntry 0xbc905e7a108766d1 0x3fefe315e86e7f85)]
    [(= index 4) (MathExpF64TableEntry 0x3c8cd2523567f613 0x3fefd9b0d3158574)]
    [(= index 5) (MathExpF64TableEntry 0xbc8bce8023f98efa 0x3fefd06b29ddf6de)]
    [(= index 6) (MathExpF64TableEntry 0x3c60f74e61e6c861 0x3fefc74518759bc8)]
    [(= index 7) (MathExpF64TableEntry 0x3c90a3e45b33d399 0x3fefbe3ecac6f383)]
    [(= index 8) (MathExpF64TableEntry 0x3c979aa65d837b6d 0x3fefb5586cf9890f)]
    [(= index 9) (MathExpF64TableEntry 0x3c8eb51a92fdeffc 0x3fefac922b7247f7)]
    [(= index 10) (MathExpF64TableEntry 0x3c3ebe3d702f9cd1 0x3fefa3ec32d3d1a2)]
    [(= index 11) (MathExpF64TableEntry 0xbc6a033489906e0b 0x3fef9b66affed31b)]
    [(= index 12) (MathExpF64TableEntry 0xbc9556522a2fbd0e 0x3fef9301d0125b51)]
    [(= index 13) (MathExpF64TableEntry 0xbc5080ef8c4eea55 0x3fef8abdc06c31cc)]
    [(= index 14) (MathExpF64TableEntry 0xbc91c923b9d5f416 0x3fef829aaea92de0)]
    [(= index 15) (MathExpF64TableEntry 0x3c80d3e3e95c55af 0x3fef7a98c8a58e51)]
    [(= index 16) (MathExpF64TableEntry 0xbc801b15eaa59348 0x3fef72b83c7d517b)]
    [(= index 17) (MathExpF64TableEntry 0xbc8f1ff055de323d 0x3fef6af9388c8dea)]
    [(= index 18) (MathExpF64TableEntry 0x3c8b898c3f1353bf 0x3fef635beb6fcb75)]
    [(= index 19) (MathExpF64TableEntry 0xbc96d99c7611eb26 0x3fef5be084045cd4)]
    [(= index 20) (MathExpF64TableEntry 0x3c9aecf73e3a2f60 0x3fef54873168b9aa)]
    [(= index 21) (MathExpF64TableEntry 0xbc8fe782cb86389d 0x3fef4d5022fcd91d)]
    [(= index 22) (MathExpF64TableEntry 0x3c8a6f4144a6c38d 0x3fef463b88628cd6)]
    [(= index 23) (MathExpF64TableEntry 0x3c807a05b0e4047d 0x3fef3f49917ddc96)]
    [(= index 24) (MathExpF64TableEntry 0x3c968efde3a8a894 0x3fef387a6e756238)]
    [(= index 25) (MathExpF64TableEntry 0x3c875e18f274487d 0x3fef31ce4fb2a63f)]
    [(= index 26) (MathExpF64TableEntry 0x3c80472b981fe7f2 0x3fef2b4565e27cdd)]
    [(= index 27) (MathExpF64TableEntry 0xbc96b87b3f71085e 0x3fef24dfe1f56381)]
    [(= index 28) (MathExpF64TableEntry 0x3c82f7e16d09ab31 0x3fef1e9df51fdee1)]
    [(= index 29) (MathExpF64TableEntry 0xbc3d219b1a6fbffa 0x3fef187fd0dad990)]
    [(= index 30) (MathExpF64TableEntry 0x3c8b3782720c0ab4 0x3fef1285a6e4030b)]
    [(= index 31) (MathExpF64TableEntry 0x3c6e149289cecb8f 0x3fef0cafa93e2f56)]
    [(= index 32) (MathExpF64TableEntry 0x3c834d754db0abb6 0x3fef06fe0a31b715)]
    [(= index 33) (MathExpF64TableEntry 0x3c864201e2ac744c 0x3fef0170fc4cd831)]
    [(= index 34) (MathExpF64TableEntry 0x3c8fdd395dd3f84a 0x3feefc08b26416ff)]
    [(= index 35) (MathExpF64TableEntry 0xbc86a3803b8e5b04 0x3feef6c55f929ff1)]
    [(= index 36) (MathExpF64TableEntry 0xbc924aedcc4b5068 0x3feef1a7373aa9cb)]
    [(= index 37) (MathExpF64TableEntry 0xbc9907f81b512d8e 0x3feeecae6d05d866)]
    [(= index 38) (MathExpF64TableEntry 0xbc71d1e83e9436d2 0x3feee7db34e59ff7)]
    [(= index 39) (MathExpF64TableEntry 0xbc991919b3ce1b15 0x3feee32dc313a8e5)]
    [(= index 40) (MathExpF64TableEntry 0x3c859f48a72a4c6d 0x3feedea64c123422)]
    [(= index 41) (MathExpF64TableEntry 0xbc9312607a28698a 0x3feeda4504ac801c)]
    [(= index 42) (MathExpF64TableEntry 0xbc58a78f4817895b 0x3feed60a21f72e2a)]
    [(= index 43) (MathExpF64TableEntry 0xbc7c2c9b67499a1b 0x3feed1f5d950a897)]
    [(= index 44) (MathExpF64TableEntry 0x3c4363ed60c2ac11 0x3feece086061892d)]
    [(= index 45) (MathExpF64TableEntry 0x3c9666093b0664ef 0x3feeca41ed1d0057)]
    [(= index 46) (MathExpF64TableEntry 0x3c6ecce1daa10379 0x3feec6a2b5c13cd0)]
    [(= index 47) (MathExpF64TableEntry 0x3c93ff8e3f0f1230 0x3feec32af0d7d3de)]
    [(= index 48) (MathExpF64TableEntry 0x3c7690cebb7aafb0 0x3feebfdad5362a27)]
    [(= index 49) (MathExpF64TableEntry 0x3c931dbdeb54e077 0x3feebcb299fddd0d)]
    [(= index 50) (MathExpF64TableEntry 0xbc8f94340071a38e 0x3feeb9b2769d2ca7)]
    [(= index 51) (MathExpF64TableEntry 0xbc87deccdc93a349 0x3feeb6daa2cf6642)]
    [(= index 52) (MathExpF64TableEntry 0xbc78dec6bd0f385f 0x3feeb42b569d4f82)]
    [(= index 53) (MathExpF64TableEntry 0xbc861246ec7b5cf6 0x3feeb1a4ca5d920f)]
    [(= index 54) (MathExpF64TableEntry 0x3c93350518fdd78e 0x3feeaf4736b527da)]
    [(= index 55) (MathExpF64TableEntry 0x3c7b98b72f8a9b05 0x3feead12d497c7fd)]
    [(= index 56) (MathExpF64TableEntry 0x3c9063e1e21c5409 0x3feeab07dd485429)]
    [(= index 57) (MathExpF64TableEntry 0x3c34c7855019c6ea 0x3feea9268a5946b7)]
    [(= index 58) (MathExpF64TableEntry 0x3c9432e62b64c035 0x3feea76f15ad2148)]
    [(= index 59) (MathExpF64TableEntry 0xbc8ce44a6199769f 0x3feea5e1b976dc09)]
    [(= index 60) (MathExpF64TableEntry 0xbc8c33c53bef4da8 0x3feea47eb03a5585)]
    [(= index 61) (MathExpF64TableEntry 0xbc845378892be9ae 0x3feea34634ccc320)]
    [(= index 62) (MathExpF64TableEntry 0xbc93cedd78565858 0x3feea23882552225)]
    [(= index 63) (MathExpF64TableEntry 0x3c5710aa807e1964 0x3feea155d44ca973)]
    [(= index 64) (MathExpF64TableEntry 0xbc93b3efbf5e2228 0x3feea09e667f3bcd)]
    [(= index 65) (MathExpF64TableEntry 0xbc6a12ad8734b982 0x3feea012750bdabf)]
    [(= index 66) (MathExpF64TableEntry 0xbc6367efb86da9ee 0x3fee9fb23c651a2f)]
    [(= index 67) (MathExpF64TableEntry 0xbc80dc3d54e08851 0x3fee9f7df9519484)]
    [(= index 68) (MathExpF64TableEntry 0xbc781f647e5a3ecf 0x3fee9f75e8ec5f74)]
    [(= index 69) (MathExpF64TableEntry 0xbc86ee4ac08b7db0 0x3fee9f9a48a58174)]
    [(= index 70) (MathExpF64TableEntry 0xbc8619321e55e68a 0x3fee9feb564267c9)]
    [(= index 71) (MathExpF64TableEntry 0x3c909ccb5e09d4d3 0x3feea0694fde5d3f)]
    [(= index 72) (MathExpF64TableEntry 0xbc7b32dcb94da51d 0x3feea11473eb0187)]
    [(= index 73) (MathExpF64TableEntry 0x3c94ecfd5467c06b 0x3feea1ed0130c132)]
    [(= index 74) (MathExpF64TableEntry 0x3c65ebe1abd66c55 0x3feea2f336cf4e62)]
    [(= index 75) (MathExpF64TableEntry 0xbc88a1c52fb3cf42 0x3feea427543e1a12)]
    [(= index 76) (MathExpF64TableEntry 0xbc9369b6f13b3734 0x3feea589994cce13)]
    [(= index 77) (MathExpF64TableEntry 0xbc805e843a19ff1e 0x3feea71a4623c7ad)]
    [(= index 78) (MathExpF64TableEntry 0xbc94d450d872576e 0x3feea8d99b4492ed)]
    [(= index 79) (MathExpF64TableEntry 0x3c90ad675b0e8a00 0x3feeaac7d98a6699)]
    [(= index 80) (MathExpF64TableEntry 0x3c8db72fc1f0eab4 0x3feeace5422aa0db)]
    [(= index 81) (MathExpF64TableEntry 0xbc65b6609cc5e7ff 0x3feeaf3216b5448c)]
    [(= index 82) (MathExpF64TableEntry 0x3c7bf68359f35f44 0x3feeb1ae99157736)]
    [(= index 83) (MathExpF64TableEntry 0xbc93091fa71e3d83 0x3feeb45b0b91ffc6)]
    [(= index 84) (MathExpF64TableEntry 0xbc5da9b88b6c1e29 0x3feeb737b0cdc5e5)]
    [(= index 85) (MathExpF64TableEntry 0xbc6c23f97c90b959 0x3feeba44cbc8520f)]
    [(= index 86) (MathExpF64TableEntry 0xbc92434322f4f9aa 0x3feebd829fde4e50)]
    [(= index 87) (MathExpF64TableEntry 0xbc85ca6cd7668e4b 0x3feec0f170ca07ba)]
    [(= index 88) (MathExpF64TableEntry 0x3c71affc2b91ce27 0x3feec49182a3f090)]
    [(= index 89) (MathExpF64TableEntry 0x3c6dd235e10a73bb 0x3feec86319e32323)]
    [(= index 90) (MathExpF64TableEntry 0xbc87c50422622263 0x3feecc667b5de565)]
    [(= index 91) (MathExpF64TableEntry 0x3c8b1c86e3e231d5 0x3feed09bec4a2d33)]
    [(= index 92) (MathExpF64TableEntry 0xbc91bbd1d3bcbb15 0x3feed503b23e255d)]
    [(= index 93) (MathExpF64TableEntry 0x3c90cc319cee31d2 0x3feed99e1330b358)]
    [(= index 94) (MathExpF64TableEntry 0x3c8469846e735ab3 0x3feede6b5579fdbf)]
    [(= index 95) (MathExpF64TableEntry 0xbc82dfcd978e9db4 0x3feee36bbfd3f37a)]
    [(= index 96) (MathExpF64TableEntry 0x3c8c1a7792cb3387 0x3feee89f995ad3ad)]
    [(= index 97) (MathExpF64TableEntry 0xbc907b8f4ad1d9fa 0x3feeee07298db666)]
    [(= index 98) (MathExpF64TableEntry 0xbc55c3d956dcaeba 0x3feef3a2b84f15fb)]
    [(= index 99) (MathExpF64TableEntry 0xbc90a40e3da6f640 0x3feef9728de5593a)]
    [(= index 100) (MathExpF64TableEntry 0xbc68d6f438ad9334 0x3feeff76f2fb5e47)]
    [(= index 101) (MathExpF64TableEntry 0xbc91eee26b588a35 0x3fef05b030a1064a)]
    [(= index 102) (MathExpF64TableEntry 0x3c74ffd70a5fddcd 0x3fef0c1e904bc1d2)]
    [(= index 103) (MathExpF64TableEntry 0xbc91bdfbfa9298ac 0x3fef12c25bd71e09)]
    [(= index 104) (MathExpF64TableEntry 0x3c736eae30af0cb3 0x3fef199bdd85529c)]
    [(= index 105) (MathExpF64TableEntry 0x3c8ee3325c9ffd94 0x3fef20ab5fffd07a)]
    [(= index 106) (MathExpF64TableEntry 0x3c84e08fd10959ac 0x3fef27f12e57d14b)]
    [(= index 107) (MathExpF64TableEntry 0x3c63cdaf384e1a67 0x3fef2f6d9406e7b5)]
    [(= index 108) (MathExpF64TableEntry 0x3c676b2c6c921968 0x3fef3720dcef9069)]
    [(= index 109) (MathExpF64TableEntry 0xbc808a1883ccb5d2 0x3fef3f0b555dc3fa)]
    [(= index 110) (MathExpF64TableEntry 0xbc8fad5d3ffffa6f 0x3fef472d4a07897c)]
    [(= index 111) (MathExpF64TableEntry 0xbc900dae3875a949 0x3fef4f87080d89f2)]
    [(= index 112) (MathExpF64TableEntry 0x3c74a385a63d07a7 0x3fef5818dcfba487)]
    [(= index 113) (MathExpF64TableEntry 0xbc82919e2040220f 0x3fef60e316c98398)]
    [(= index 114) (MathExpF64TableEntry 0x3c8e5a50d5c192ac 0x3fef69e603db3285)]
    [(= index 115) (MathExpF64TableEntry 0x3c843a59ac016b4b 0x3fef7321f301b460)]
    [(= index 116) (MathExpF64TableEntry 0xbc82d52107b43e1f 0x3fef7c97337b9b5f)]
    [(= index 117) (MathExpF64TableEntry 0xbc892ab93b470dc9 0x3fef864614f5a129)]
    [(= index 118) (MathExpF64TableEntry 0x3c74b604603a88d3 0x3fef902ee78b3ff6)]
    [(= index 119) (MathExpF64TableEntry 0x3c83c5ec519d7271 0x3fef9a51fbc74c83)]
    [(= index 120) (MathExpF64TableEntry 0xbc8ff7128fd391f0 0x3fefa4afa2a490da)]
    [(= index 121) (MathExpF64TableEntry 0xbc8dae98e223747d 0x3fefaf482d8e67f1)]
    [(= index 122) (MathExpF64TableEntry 0x3c8ec3bc41aa2008 0x3fefba1bee615a27)]
    [(= index 123) (MathExpF64TableEntry 0x3c842b94c3a9eb32 0x3fefc52b376bba97)]
    [(= index 124) (MathExpF64TableEntry 0x3c8a64a931d185ee 0x3fefd0765b6e4540)]
    [(= index 125) (MathExpF64TableEntry 0xbc8e37bae43be3ed 0x3fefdbfdad9cbe14)]
    [(= index 126) (MathExpF64TableEntry 0x3c77893b4d91cd9d 0x3fefe7c1819e90d8)]
    [(= index 127) (MathExpF64TableEntry 0x3c5305c14160cc89 0x3feff3c22b8f71f1)]
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

;; The logarithm implementation below follows musl `log`/`logf` and their
;; data tables at revision b306b16af15c89a04d8e0c55cac2dadbeb39c083.
;; Constants remain exact IEEE-754 bit patterns. Binary64 deliberately uses
;; musl's non-FMA reduction, and the written operation order is part of the
;; round-to-nearest error bound.
(defstruct MathLogF64TableEntry
  (invc-bits u64)
  (logc-bits u64)
  (chi-bits u64)
  (clo-bits u64))

(defstruct MathLogF32TableEntry
  (invc-bits u64)
  (logc-bits u64))

;: Return one exact non-FMA binary64 log reduction-table entry.
(define (math-log-f64-table-entry [index : i64]) : MathLogF64TableEntry
  (cond
    [(= index 0)
      (MathLogF64TableEntry
        0x3ff734f0c3e0de9f
        0xbfd7cc7f79e69000
        0x3fe61000014fb66b
        0x3c7e026c91425b3c)]
    [(= index 1)
      (MathLogF64TableEntry
        0x3ff713786a2ce91f
        0xbfd76feec20d0000
        0x3fe63000034db495
        0x3c8dbfea48005d41)]
    [(= index 2)
      (MathLogF64TableEntry
        0x3ff6f26008fab5a0
        0xbfd713e31351e000
        0x3fe650000d94d478
        0x3c8e7fa786d6a5b7)]
    [(= index 3)
      (MathLogF64TableEntry
        0x3ff6d1a61f138c7d
        0xbfd6b85b38287800
        0x3fe67000074e6fad
        0x3c61fcea6b54254c)]
    [(= index 4)
      (MathLogF64TableEntry
        0x3ff6b1490bc5b4d1
        0xbfd65d5590807800
        0x3fe68ffffedf0fae
        0xbc7c7e274c590efd)]
    [(= index 5)
      (MathLogF64TableEntry
        0x3ff69147332f0cba
        0xbfd602d076180000
        0x3fe6b0000763c5bc
        0xbc8ac16848dcda01)]
    [(= index 6)
      (MathLogF64TableEntry
        0x3ff6719f18224223
        0xbfd5a8ca86909000
        0x3fe6d0001e5cc1f6
        0x3c833f1c9d499311)]
    [(= index 7)
      (MathLogF64TableEntry
        0x3ff6524f99a51ed9
        0xbfd54f4356035000
        0x3fe6efffeb05f63e
        0xbc7e80041ae22d53)]
    [(= index 8)
      (MathLogF64TableEntry
        0x3ff63356aa8f24c4
        0xbfd4f637c36b4000
        0x3fe710000e869780
        0x3c7bff6671097952)]
    [(= index 9)
      (MathLogF64TableEntry
        0x3ff614b36b9ddc14
        0xbfd49da7fda85000
        0x3fe72ffffc67e912
        0x3c8c00e226bd8724)]
    [(= index 10)
      (MathLogF64TableEntry
        0x3ff5f66452c65c4c
        0xbfd445923989a800
        0x3fe74fffdf81116a
        0xbc6e02916ef101d2)]
    [(= index 11)
      (MathLogF64TableEntry
        0x3ff5d867b5912c4f
        0xbfd3edf439b0b800
        0x3fe770000f679c90
        0xbc67fc71cd549c74)]
    [(= index 12)
      (MathLogF64TableEntry
        0x3ff5babccb5b90de
        0xbfd396ce448f7000
        0x3fe78ffffa7ec835
        0x3c81bec19ef50483)]
    [(= index 13)
      (MathLogF64TableEntry
        0x3ff59d61f2d91a78
        0xbfd3401e17bda000
        0x3fe7affffe20c2e6
        0xbc707e1729cc6465)]
    [(= index 14)
      (MathLogF64TableEntry
        0x3ff5805612465687
        0xbfd2e9e2ef468000
        0x3fe7cfffed3fc900
        0xbc808072087b8b1c)]
    [(= index 15)
      (MathLogF64TableEntry
        0x3ff56397cee76bd3
        0xbfd2941b3830e000
        0x3fe7efffe9261a76
        0x3c8dc0286d9df9ae)]
    [(= index 16)
      (MathLogF64TableEntry
        0x3ff54725e2a77f93
        0xbfd23ec58cda8800
        0x3fe81000049ca3e8
        0x3c897fd251e54c33)]
    [(= index 17)
      (MathLogF64TableEntry
        0x3ff52aff42064583
        0xbfd1e9e129279000
        0x3fe8300017932c8f
        0xbc8afee9b630f381)]
    [(= index 18)
      (MathLogF64TableEntry
        0x3ff50f22dbb2bddf
        0xbfd1956d2b48f800
        0x3fe850000633739c
        0x3c89bfbf6b6535bc)]
    [(= index 19)
      (MathLogF64TableEntry
        0x3ff4f38f4734ded7
        0xbfd141679ab9f800
        0x3fe87000204289c6
        0xbc8bbf65f3117b75)]
    [(= index 20)
      (MathLogF64TableEntry
        0x3ff4d843cfde2840
        0xbfd0edd094ef9800
        0x3fe88fffebf57904
        0xbc89006ea23dcb57)]
    [(= index 21)
      (MathLogF64TableEntry
        0x3ff4bd3ec078a3c8
        0xbfd09aa518db1000
        0x3fe8b00022bc04df
        0xbc7d00df38e04b0a)]
    [(= index 22)
      (MathLogF64TableEntry
        0x3ff4a27fc3e0258a
        0xbfd047e65263b800
        0x3fe8cfffe50c1b8a
        0xbc88007146ff9f05)]
    [(= index 23)
      (MathLogF64TableEntry
        0x3ff4880524d48434
        0xbfcfeb224586f000
        0x3fe8effffc918e43
        0x3c83817bd07a7038)]
    [(= index 24)
      (MathLogF64TableEntry
        0x3ff46dce1b192d0b
        0xbfcf474a7517b000
        0x3fe910001efa5fc7
        0x3c893e9176dfb403)]
    [(= index 25)
      (MathLogF64TableEntry
        0x3ff453d9d3391854
        0xbfcea4443d103000
        0x3fe9300013467bb9
        0x3c7f804e4b980276)]
    [(= index 26)
      (MathLogF64TableEntry
        0x3ff43a2744b4845a
        0xbfce020d44e9b000
        0x3fe94fffe6ee076f
        0xbc8f7ef0d9ff622e)]
    [(= index 27)
      (MathLogF64TableEntry
        0x3ff420b54115f8fb
        0xbfcd60a22977f000
        0x3fe96fffde3c12d1
        0xbc7082aa962638ba)]
    [(= index 28)
      (MathLogF64TableEntry
        0x3ff40782da3ef4b1
        0xbfccc00104959000
        0x3fe98ffff4458a0d
        0xbc87801b9164a8ef)]
    [(= index 29)
      (MathLogF64TableEntry
        0x3ff3ee8f5d57fe8f
        0xbfcc202956891000
        0x3fe9afffdd982e3e
        0xbc8740e08a5a9337)]
    [(= index 30)
      (MathLogF64TableEntry
        0x3ff3d5d9a00b4ce9
        0xbfcb81178d811000
        0x3fe9cfffed49fb66
        0x3c3fce08c19be000)]
    [(= index 31)
      (MathLogF64TableEntry
        0x3ff3bd60c010c12b
        0xbfcae2c9ccd3d000
        0x3fe9f00020f19c51
        0xbc8a3faa27885b0a)]
    [(= index 32)
      (MathLogF64TableEntry
        0x3ff3a5242b75dab8
        0xbfca45402e129000
        0x3fea10001145b006
        0x3c74ff489958da56)]
    [(= index 33)
      (MathLogF64TableEntry
        0x3ff38d22cd9fd002
        0xbfc9a877681df000
        0x3fea300007bbf6fa
        0x3c8cbeab8a2b6d18)]
    [(= index 34)
      (MathLogF64TableEntry
        0x3ff3755bc5847a1c
        0xbfc90c6d69483000
        0x3fea500010971d79
        0x3c88fecadd787930)]
    [(= index 35)
      (MathLogF64TableEntry
        0x3ff35dce49ad36e2
        0xbfc87120a645c000
        0x3fea70001df52e48
        0xbc8f41763dd8abdb)]
    [(= index 36)
      (MathLogF64TableEntry
        0x3ff34679984dd440
        0xbfc7d68fb4143000
        0x3fea90001c593352
        0xbc8ebf0284c27612)]
    [(= index 37)
      (MathLogF64TableEntry
        0x3ff32f5cceffcb24
        0xbfc73cb83c627000
        0x3feab0002a4f3e4b
        0xbc69fd043cff3f5f)]
    [(= index 38)
      (MathLogF64TableEntry
        0x3ff3187775a10d49
        0xbfc6a39a9b376000
        0x3feacfffd7ae1ed1
        0xbc823ee7129070b4)]
    [(= index 39)
      (MathLogF64TableEntry
        0x3ff301c8373e3990
        0xbfc60b3154b7a000
        0x3feaefffee510478
        0x3c6a063ee00edea3)]
    [(= index 40)
      (MathLogF64TableEntry
        0x3ff2eb4ebb95f841
        0xbfc5737d76243000
        0x3feb0fffdb650d5b
        0x3c5a06c8381f0ab9)]
    [(= index 41)
      (MathLogF64TableEntry
        0x3ff2d50a0219a9d1
        0xbfc4dc7b8fc23000
        0x3feb2ffffeaaca57
        0xbc79011e74233c1d)]
    [(= index 42)
      (MathLogF64TableEntry
        0x3ff2bef9a8b7fd2a
        0xbfc4462c51d20000
        0x3feb4fffd995badc
        0xbc79ff1068862a9f)]
    [(= index 43)
      (MathLogF64TableEntry
        0x3ff2a91c7a0c1bab
        0xbfc3b08abc830000
        0x3feb7000249e659c
        0x3c8aff45d0864f3e)]
    [(= index 44)
      (MathLogF64TableEntry
        0x3ff293726014b530
        0xbfc31b996b490000
        0x3feb8ffff9871640
        0x3c7cfe7796c2c3f9)]
    [(= index 45)
      (MathLogF64TableEntry
        0x3ff27dfa5757a1f5
        0xbfc2875490a44000
        0x3febafffd204cb4f
        0xbc63ff27eef22bc4)]
    [(= index 46)
      (MathLogF64TableEntry
        0x3ff268b39b1d3bbf
        0xbfc1f3b9f879a000
        0x3febcfffd2415c45
        0xbc6cffb7ee3bea21)]
    [(= index 47)
      (MathLogF64TableEntry
        0x3ff2539d838ff5bd
        0xbfc160c8252ca000
        0x3febeffff86309df
        0xbc814103972e0b5c)]
    [(= index 48)
      (MathLogF64TableEntry
        0x3ff23eb7aac9083b
        0xbfc0ce7f57f72000
        0x3fec0fffe1b57653
        0x3c8bc16494b76a19)]
    [(= index 49)
      (MathLogF64TableEntry
        0x3ff22a012ba940b6
        0xbfc03cdc49fea000
        0x3fec2ffff1fa57e3
        0xbc64feef8d30c6ed)]
    [(= index 50)
      (MathLogF64TableEntry
        0x3ff2157996cc4132
        0xbfbf57bdbc4b8000
        0x3fec4fffdcbfe424
        0xbc843f68bcec4775)]
    [(= index 51)
      (MathLogF64TableEntry
        0x3ff201201dd2fc9b
        0xbfbe370896404000
        0x3fec6fffed54b9f7
        0x3c847ea3f053e0ec)]
    [(= index 52)
      (MathLogF64TableEntry
        0x3ff1ecf4494d480b
        0xbfbd17983ef94000
        0x3fec8fffeb998fd5
        0x3c7383068df992f1)]
    [(= index 53)
      (MathLogF64TableEntry
        0x3ff1d8f5528f6569
        0xbfbbf9674ed8a000
        0x3fecb0002125219a
        0xbc68fd8e64180e04)]
    [(= index 54)
      (MathLogF64TableEntry
        0x3ff1c52311577e7c
        0xbfbadc79202f6000
        0x3feccfffdd94469c
        0x3c8e7ebe1cc7ea72)]
    [(= index 55)
      (MathLogF64TableEntry
        0x3ff1b17c74cb26e9
        0xbfb9c0c3e7288000
        0x3fecefffeafdc476
        0x3c8ebe39ad9f88fe)]
    [(= index 56)
      (MathLogF64TableEntry
        0x3ff19e010c2c1ab6
        0xbfb8a646b372c000
        0x3fed1000169af82b
        0x3c757d91a8b95a71)]
    [(= index 57)
      (MathLogF64TableEntry
        0x3ff18ab07bb670bd
        0xbfb78d01b3ac0000
        0x3fed30000d0ff71d
        0x3c89c1906970c7da)]
    [(= index 58)
      (MathLogF64TableEntry
        0x3ff1778a25efbcb6
        0xbfb674f145380000
        0x3fed4fffea790fc4
        0xbc580e37c558fe0c)]
    [(= index 59)
      (MathLogF64TableEntry
        0x3ff1648d354c31da
        0xbfb55e0e6d878000
        0x3fed70002edc87e5
        0xbc7f80d64dc10f44)]
    [(= index 60)
      (MathLogF64TableEntry
        0x3ff151b990275fdd
        0xbfb4485cdea1e000
        0x3fed900021dc82aa
        0xbc747c8f94fd5c5c)]
    [(= index 61)
      (MathLogF64TableEntry
        0x3ff13f0ea432d24c
        0xbfb333d94d6aa000
        0x3fedafffd86b0283
        0x3c8c7f1dc521617e)]
    [(= index 62)
      (MathLogF64TableEntry
        0x3ff12c8b7210f9da
        0xbfb22079f8c56000
        0x3fedd000296c4739
        0x3c88019eb2ffb153)]
    [(= index 63)
      (MathLogF64TableEntry
        0x3ff11a3028ecb531
        0xbfb10e4698622000
        0x3fedefffe54490f5
        0x3c6e00d2c652cc89)]
    [(= index 64)
      (MathLogF64TableEntry
        0x3ff107fbda8434af
        0xbfaffa6c6ad20000
        0x3fee0fffcdabf694
        0xbc7f8340202d69d2)]
    [(= index 65)
      (MathLogF64TableEntry
        0x3ff0f5ee0f4e6bb3
        0xbfadda8d4a774000
        0x3fee2fffdb52c8dd
        0x3c7b00c1ca1b0864)]
    [(= index 66)
      (MathLogF64TableEntry
        0x3ff0e4065d2a9fce
        0xbfabbcece4850000
        0x3fee4ffff24216ef
        0x3c72ffa8b094ab51)]
    [(= index 67)
      (MathLogF64TableEntry
        0x3ff0d244632ca521
        0xbfa9a1894012c000
        0x3fee6fffe88a5e11
        0xbc57f673b1efbe59)]
    [(= index 68)
      (MathLogF64TableEntry
        0x3ff0c0a77ce2981a
        0xbfa788583302c000
        0x3fee9000119eff0d
        0xbc84808d5e0bc801)]
    [(= index 69)
      (MathLogF64TableEntry
        0x3ff0af2f83c636d1
        0xbfa5715e67d68000
        0x3feeafffdfa51744
        0x3c780006d54320b5)]
    [(= index 70)
      (MathLogF64TableEntry
        0x3ff09ddb98a01339
        0xbfa35c8a49658000
        0x3feed0001a127fa1
        0xbc5002f860565c92)]
    [(= index 71)
      (MathLogF64TableEntry
        0x3ff08cabaf52e7df
        0xbfa149e364154000
        0x3feef00007babcc4
        0xbc8540445d35e611)]
    [(= index 72)
      (MathLogF64TableEntry
        0x3ff07b9f2f4e28fb
        0xbf9e72c082eb8000
        0x3fef0ffff57a8d02
        0xbc4ffb3139ef9105)]
    [(= index 73)
      (MathLogF64TableEntry
        0x3ff06ab58c358f19
        0xbf9a55f152528000
        0x3fef30001ee58ac7
        0x3c8a81acf2731155)]
    [(= index 74)
      (MathLogF64TableEntry
        0x3ff059eea5ecf92c
        0xbf963d62cf818000
        0x3fef4ffff5823494
        0x3c8a3f41d4d7c743)]
    [(= index 75)
      (MathLogF64TableEntry
        0x3ff04949cdd12c90
        0xbf9228fb8caa0000
        0x3fef6ffffca94c6b
        0xbc6202f41c987875)]
    [(= index 76)
      (MathLogF64TableEntry
        0x3ff038c6c6f0ada9
        0xbf8c317b20f90000
        0x3fef8fffe1f9c441
        0x3c777dd1f477e74b)]
    [(= index 77)
      (MathLogF64TableEntry
        0x3ff02865137932a9
        0xbf8419355daa0000
        0x3fefafffd2e0e37e
        0xbc6f01199a7ca331)]
    [(= index 78)
      (MathLogF64TableEntry
        0x3ff0182427ea7348
        0xbf781203c2ec0000
        0x3fefd0001c77e49e
        0x3c7181ee4bceacb1)]
    [(= index 79)
      (MathLogF64TableEntry
        0x3ff008040614b195
        0xbf60040979240000
        0x3fefeffff7e0c331
        0xbc6e05370170875a)]
    [(= index 80)
      (MathLogF64TableEntry
        0x3fefe01ff726fa1a
        0x3f6feff384900000
        0x3ff00ffff465606e
        0xbc8a7ead491c0ada)]
    [(= index 81)
      (MathLogF64TableEntry
        0x3fefa11cc261ea74
        0x3f87dc41353d0000
        0x3ff02ffff3867a58
        0xbc977f69c3fcb2e0)]
    [(= index 82)
      (MathLogF64TableEntry
        0x3fef6310b081992e
        0x3f93cea3c4c28000
        0x3ff04ffffdfc0d17
        0x3c97bffe34cb945b)]
    [(= index 83)
      (MathLogF64TableEntry
        0x3fef25f63ceeadcd
        0x3f9b9fc114890000
        0x3ff0700003cd4d82
        0x3c820083c0e456cb)]
    [(= index 84)
      (MathLogF64TableEntry
        0x3feee9c8039113e7
        0x3fa1b0d8ce110000
        0x3ff08ffff9f2cbe8
        0xbc6dffdfbe37751a)]
    [(= index 85)
      (MathLogF64TableEntry
        0x3feeae8078cbb1ab
        0x3fa58a5bd001c000
        0x3ff0b000010cda65
        0xbc913f7faee626eb)]
    [(= index 86)
      (MathLogF64TableEntry
        0x3fee741aa29d0c9b
        0x3fa95c8340d88000
        0x3ff0d00001a4d338
        0x3c807dfa79489ff7)]
    [(= index 87)
      (MathLogF64TableEntry
        0x3fee3a91830a99b5
        0x3fad276aef578000
        0x3ff0effffadafdfd
        0xbc77040570d66bc0)]
    [(= index 88)
      (MathLogF64TableEntry
        0x3fee01e009609a56
        0x3fb07598e598c000
        0x3ff110000bbafd96
        0x3c8e80d4846d0b62)]
    [(= index 89)
      (MathLogF64TableEntry
        0x3fedca01e577bb98
        0x3fb253f5e30d2000
        0x3ff12ffffae5f45d
        0x3c9dbffa64fd36ef)]
    [(= index 90)
      (MathLogF64TableEntry
        0x3fed92f20b7c9103
        0x3fb42edd8b380000
        0x3ff150000dd59ad9
        0x3c9a0077701250ae)]
    [(= index 91)
      (MathLogF64TableEntry
        0x3fed5cac66fb5cce
        0x3fb606598757c000
        0x3ff170000f21559a
        0x3c8dfdf9e2e3deee)]
    [(= index 92)
      (MathLogF64TableEntry
        0x3fed272caa5ede9d
        0x3fb7da76356a0000
        0x3ff18ffffc275426
        0x3c910030dc3b7273)]
    [(= index 93)
      (MathLogF64TableEntry
        0x3fecf26e3e6b2ccd
        0x3fb9ab434e1c6000
        0x3ff1b000123d3c59
        0x3c997f7980030188)]
    [(= index 94)
      (MathLogF64TableEntry
        0x3fecbe6da2a77902
        0x3fbb78c7bb0d6000
        0x3ff1cffff8299eb7
        0xbc65f932ab9f8c67)]
    [(= index 95)
      (MathLogF64TableEntry
        0x3fec8b266d37086d
        0x3fbd431332e72000
        0x3ff1effff48ad400
        0x3c937fbf9da75beb)]
    [(= index 96)
      (MathLogF64TableEntry
        0x3fec5894bd5d5804
        0x3fbf0a3171de6000
        0x3ff210000c8b86a4
        0x3c9f806b91fd5b22)]
    [(= index 97)
      (MathLogF64TableEntry
        0x3fec26b533bb9f8c
        0x3fc067152b914000
        0x3ff2300003854303
        0x3c93ffc2eb9fbf33)]
    [(= index 98)
      (MathLogF64TableEntry
        0x3febf583eeece73f
        0x3fc147858292b000
        0x3ff24fffffbcf684
        0x3c7601e77e2e2e72)]
    [(= index 99)
      (MathLogF64TableEntry
        0x3febc4fd75db96c1
        0x3fc2266ecdca3000
        0x3ff26ffff52921d9
        0x3c7ffcbb767f0c61)]
    [(= index 100)
      (MathLogF64TableEntry
        0x3feb951e0c864a28
        0x3fc303d7a6c55000
        0x3ff2900014933a3c
        0xbc7202ca3c02412b)]
    [(= index 101)
      (MathLogF64TableEntry
        0x3feb65e2c5ef3e2c
        0x3fc3dfc33c331000
        0x3ff2b00014556313
        0xbc92808233f21f02)]
    [(= index 102)
      (MathLogF64TableEntry
        0x3feb374867c9888b
        0x3fc4ba366b7a8000
        0x3ff2cfffebfe523b
        0xbc88ff7e384fdcf2)]
    [(= index 103)
      (MathLogF64TableEntry
        0x3feb094b211d304a
        0x3fc5933928d1f000
        0x3ff2f0000bb8ad96
        0xbc85ff51503041c5)]
    [(= index 104)
      (MathLogF64TableEntry
        0x3feadbe885f2ef7e
        0x3fc66acd2418f000
        0x3ff30ffffb7ae2af
        0xbc810071885e289d)]
    [(= index 105)
      (MathLogF64TableEntry
        0x3feaaf1d31603da2
        0x3fc740f8ec669000
        0x3ff32ffffeac5f7f
        0xbc91ff5d3fb7b715)]
    [(= index 106)
      (MathLogF64TableEntry
        0x3fea82e63fd358a7
        0x3fc815c0f51af000
        0x3ff350000ca66756
        0x3c957f82228b82bd)]
    [(= index 107)
      (MathLogF64TableEntry
        0x3fea5740ef09738b
        0x3fc8e92954f68000
        0x3ff3700011fbf721
        0x3c8000bac40dd5cc)]
    [(= index 108)
      (MathLogF64TableEntry
        0x3fea2c2a90ab4b27
        0x3fc9bb3602f84000
        0x3ff38ffff9592fb9
        0xbc943f9d2db2a751)]
    [(= index 109)
      (MathLogF64TableEntry
        0x3fea01a01393f2d1
        0x3fca8bed1c2c0000
        0x3ff3b00004ddd242
        0x3c857f6b707638e1)]
    [(= index 110)
      (MathLogF64TableEntry
        0x3fe9d79f24db3c1b
        0x3fcb5b515c01d000
        0x3ff3cffff5b2c957
        0x3c7a023a10bf1231)]
    [(= index 111)
      (MathLogF64TableEntry
        0x3fe9ae2505c7b190
        0x3fcc2967ccbcc000
        0x3ff3efffeab0b418
        0x3c987f6d66b152b0)]
    [(= index 112)
      (MathLogF64TableEntry
        0x3fe9852ef297ce2f
        0x3fccf635d5486000
        0x3ff410001532aff4
        0x3c67f8375f198524)]
    [(= index 113)
      (MathLogF64TableEntry
        0x3fe95cbaeea44b75
        0x3fcdc1bd3446c000
        0x3ff4300017478b29
        0x3c8301e672dc5143)]
    [(= index 114)
      (MathLogF64TableEntry
        0x3fe934c69de74838
        0x3fce8c01b8cfe000
        0x3ff44fffe795b463
        0x3c89ff69b8b2895a)]
    [(= index 115)
      (MathLogF64TableEntry
        0x3fe90d4f2f6752e6
        0x3fcf5509c0179000
        0x3ff46fffe80475e0
        0xbc95c0b19bc2f254)]
    [(= index 116)
      (MathLogF64TableEntry
        0x3fe8e6528effd79d
        0x3fd00e6c121fb800
        0x3ff48fffef6fc1e7
        0x3c9b4009f23a2a72)]
    [(= index 117)
      (MathLogF64TableEntry
        0x3fe8bfce9fcc007c
        0x3fd071b80e93d000
        0x3ff4afffe5bea704
        0xbc94ffb7bf0d7d45)]
    [(= index 118)
      (MathLogF64TableEntry
        0x3fe899c0dabec30e
        0x3fd0d46b9e867000
        0x3ff4d000171027de
        0xbc99c06471dc6a3d)]
    [(= index 119)
      (MathLogF64TableEntry
        0x3fe87427aa2317fb
        0x3fd13687334bd000
        0x3ff4f0000ff03ee2
        0x3c977f890b85531c)]
    [(= index 120)
      (MathLogF64TableEntry
        0x3fe84f00acb39a08
        0x3fd1980d67234800
        0x3ff5100012dc4bd1
        0x3c6004657166a436)]
    [(= index 121)
      (MathLogF64TableEntry
        0x3fe82a49e8653e55
        0x3fd1f8ffe0cc8000
        0x3ff530001605277a
        0xbc96bfcece233209)]
    [(= index 122)
      (MathLogF64TableEntry
        0x3fe8060195f40260
        0x3fd2595fd7636800
        0x3ff54fffecdb704c
        0xbc8902720505a1d7)]
    [(= index 123)
      (MathLogF64TableEntry
        0x3fe7e22563e0a329
        0x3fd2b9300914a800
        0x3ff56fffef5f54a9
        0x3c9bbfe60ec96412)]
    [(= index 124)
      (MathLogF64TableEntry
        0x3fe7beb377dcb5ad
        0x3fd3187210436000
        0x3ff5900017e61012
        0x3c887ec581afef90)]
    [(= index 125)
      (MathLogF64TableEntry
        0x3fe79baa679725c2
        0x3fd377266dec1800
        0x3ff5b00003c93e92
        0xbc9f41080abf0cc0)]
    [(= index 126)
      (MathLogF64TableEntry
        0x3fe77907f2170657
        0x3fd3d54ffbaf3000
        0x3ff5d0001d4919bc
        0xbc98812afb254729)]
    [(= index 127)
      (MathLogF64TableEntry
        0x3fe756cadbd6130c
        0x3fd432eee32fe000
        0x3ff5efffe7b87a89
        0xbc947eb780ed6904)]
    [else (MathLogF64TableEntry 0 0 0 0)]))

;: Return one exact binary32 log reduction-table entry.
(define (math-log-f32-table-entry [index : i64]) : MathLogF32TableEntry
  (cond
    [(= index 0) (MathLogF32TableEntry 0x3ff661ec79f8f3be 0xbfd57bf7808caade)]
    [(= index 1) (MathLogF32TableEntry 0x3ff571ed4aaf883d 0xbfd2bef0a7c06ddb)]
    [(= index 2) (MathLogF32TableEntry 0x3ff49539f0f010b0 0xbfd01eae7f513a67)]
    [(= index 3) (MathLogF32TableEntry 0x3ff3c995b0b80385 0xbfcb31d8a68224e9)]
    [(= index 4) (MathLogF32TableEntry 0x3ff30d190c8864a5 0xbfc6574f0ac07758)]
    [(= index 5) (MathLogF32TableEntry 0x3ff25e227b0b8ea0 0xbfc1aa2bc79c8100)]
    [(= index 6) (MathLogF32TableEntry 0x3ff1bb4a4a1a343f 0xbfba4e76ce8c0e5e)]
    [(= index 7) (MathLogF32TableEntry 0x3ff12358f08ae5ba 0xbfb1973c5a611ccc)]
    [(= index 8) (MathLogF32TableEntry 0x3ff0953f419900a7 0xbfa252f438e10c1e)]
    [(= index 9) (MathLogF32TableEntry 0x3ff0000000000000 0x0000000000000000)]
    [(= index 10) (MathLogF32TableEntry 0x3fee608cfd9a47ac 0x3faaa5aa5df25984)]
    [(= index 11) (MathLogF32TableEntry 0x3feca4b31f026aa0 0x3fbc5e53aa362eb4)]
    [(= index 12) (MathLogF32TableEntry 0x3feb2036576afce6 0x3fc526e57720db08)]
    [(= index 13) (MathLogF32TableEntry 0x3fe9c2d163a1aa2d 0x3fcbc2860d224770)]
    [(= index 14) (MathLogF32TableEntry 0x3fe886e6037841ed 0x3fd1058bc8a07ee1)]
    [(= index 15) (MathLogF32TableEntry 0x3fe767dcf5534862 0x3fd4043057b6ee09)]
    [else (MathLogF32TableEntry 0 0)]))

;: Evaluate the compensated binary64 log polynomial for inputs close to one.
(define (math-log-f64-near-one [value : f64]) : f64
  (let
    [r : f64 (- value 1.0)]
    [r2 : f64 (* r r)]
    [r3 : f64 (* r r2)]
    [b0 : f64 (stdlib.math.f64-from-bits 0xbfe0000000000000)]
    [y0 : f64
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
    [w0 : f64 (* r (stdlib.math.f64-from-bits 0x41a0000000000000))]
    [rhi : f64 (- (+ r w0) w0)]
    [rlo : f64 (- r rhi)]
    [w : f64 (* (* rhi rhi) b0)]
    [hi : f64 (+ r w)]
    [lo0 : f64 (+ (- r hi) w)]
    [lo : f64 (+ lo0 (* (* b0 rlo) (+ rhi r)))]
    (+ (+ y0 lo) hi)))

;: Return natural log(`value`) as binary64 without allocation or platform calls.
;:
;: The implementation uses musl's 128-way non-FMA table reduction plus a
;: compensated near-one path. Its documented worst-case error is about 0.507
;: ULP in default round-to-nearest mode. Both signed zeros map to negative
;: infinity; negative finite values and negative infinity map to NaN; one maps
;: to positive zero; positive infinity is unchanged; and NaNs remain NaN.
;: Floating exception flags and signaling-NaN payload behavior are outside the
;: initial contract.
(define (f64-log [value : f64]) : f64
  (let
    [bits : u64 (stdlib.math.f64-to-bits value)]
    (if (and
      (>= bits (cast 0x3fee000000000000 : u64))
      (< bits (cast 0x3ff1090000000000 : u64)))
      (if (= bits (cast 0x3ff0000000000000 : u64))
        0.0
        (math-log-f64-near-one value))
      (let
        [magnitude : u64 (bit-and bits 0x7fffffffffffffff)]
        (cond
          [(= magnitude (cast 0 : u64)) (stdlib.math.f64-negative-infinity)]
          [(!= (bit-and bits 0x8000000000000000) (cast 0 : u64))
            (stdlib.math.f64-quiet-nan)]
          [(= bits (cast 0x7ff0000000000000 : u64)) value]
          [(> bits (cast 0x7ff0000000000000 : u64)) (+ value value)]
          [else
            (let
              [ix : u64
                (if (< bits (cast 0x0010000000000000 : u64))
                  (-
                    (stdlib.math.f64-to-bits
                      (* value (stdlib.math.f64-from-bits 0x4330000000000000)))
                    (shl (cast 52 : u64) 52))
                  bits)]
              [tmp : u64 (- ix (cast 0x3fe6000000000000 : u64))]
              [index : i64 (cast (% (shr tmp 45) (cast 128 : u64)) : i64)]
              [k : i64 (shr (cast tmp : i64) 52)]
              [iz : u64 (- ix (bit-and tmp 0xfff0000000000000))]
              [entry : MathLogF64TableEntry (math-log-f64-table-entry index)]
              [invc : f64
                (stdlib.math.f64-from-bits (struct-get entry invc-bits))]
              [logc : f64
                (stdlib.math.f64-from-bits (struct-get entry logc-bits))]
              [chi : f64
                (stdlib.math.f64-from-bits (struct-get entry chi-bits))]
              [clo : f64
                (stdlib.math.f64-from-bits (struct-get entry clo-bits))]
              [z : f64 (stdlib.math.f64-from-bits iz)]
              [r : f64 (* (- (- z chi) clo) invc)]
              [kd : f64 (cast k : f64)]
              [w : f64
                (+ (* kd (stdlib.math.f64-from-bits 0x3fe62e42fefa3800)) logc)]
              [hi : f64 (+ w r)]
              [lo : f64
                (+
                  (+ (- w hi) r)
                  (* kd (stdlib.math.f64-from-bits 0x3d2ef35793c76730)))]
              [r2 : f64 (* r r)]
              [correction : f64
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
                        (* r (stdlib.math.f64-from-bits 0xbfc55575e506c89f))))))]
              (+
                (+
                  (+ lo (* r2 (stdlib.math.f64-from-bits 0xbfe0000000000001)))
                  correction)
                hi))])))))

;: Return natural log(`value`) as binary32 without allocation or platform calls.
;:
;: The implementation evaluates a 16-way table reduction and degree-three
;: polynomial in binary64 before the final binary32 rounding. Its documented
;: worst-case error is about 0.818 ULP in default round-to-nearest mode, with
;: the same special-value contract as `f64-log`.
(define (f32-log [value : f32]) : f32
  (let
    [bits : u32 (stdlib.math.f32-to-bits value)]
    [magnitude : u32 (bit-and bits (cast 0x7fffffff : u32))]
    (cond
      [(= magnitude (cast 0 : u32)) (stdlib.math.f32-negative-infinity)]
      [(!= (bit-and bits (cast 0x80000000 : u32)) (cast 0 : u32))
        (stdlib.math.f32-quiet-nan)]
      [(= bits (cast 0x3f800000 : u32)) (cast 0.0 : f32)]
      [(= bits (cast 0x7f800000 : u32)) value]
      [(> bits (cast 0x7f800000 : u32)) (+ value value)]
      [else
        (let
          [ix : u32
            (if (< bits (cast 0x00800000 : u32))
              (-
                (stdlib.math.f32-to-bits
                  (* value (stdlib.math.f32-from-bits (cast 0x4b000000 : u32))))
                (shl (cast 23 : u32) 23))
              bits)]
          [tmp : u32 (- ix (cast 0x3f330000 : u32))]
          [index : i64 (cast (% (shr tmp 19) (cast 16 : u32)) : i64)]
          [k : i64 (cast (shr (cast tmp : i32) 23) : i64)]
          [iz : u32 (- ix (bit-and tmp (cast 0xff800000 : u32)))]
          [entry : MathLogF32TableEntry (math-log-f32-table-entry index)]
          [invc : f64 (stdlib.math.f64-from-bits (struct-get entry invc-bits))]
          [logc : f64 (stdlib.math.f64-from-bits (struct-get entry logc-bits))]
          [z : f64 (cast (stdlib.math.f32-from-bits iz) : f64)]
          [r : f64 (- (* z invc) 1.0)]
          [r2 : f64 (* r r)]
          [y0 : f64
            (+
              logc
              (* (cast k : f64) (stdlib.math.f64-from-bits 0x3fe62e42fefa39ef)))]
          [y1 : f64
            (+
              (* (stdlib.math.f64-from-bits 0x3fd5575b0be00b6a) r)
              (stdlib.math.f64-from-bits 0xbfdffffef20a4123))]
          [y2 : f64
            (+ (* (stdlib.math.f64-from-bits 0xbfd00ea348b88334) r2) y1)]
          (cast (+ (* y2 r2) (+ y0 r)) : f32))])))

;: Return natural log(`value`) for an `f64` or `f32` expression.
;:
;: The expression is evaluated exactly once and its precision is preserved.
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
    (if (and
      (= calls 1)
      (= (stdlib.math.f64-to-bits once) (cast 0x3fe62e42fefa39ef : u64))
      (= (stdlib.math.f32-to-bits log32) (cast 0x3f317218 : u32))
      (= (stdlib.math.f64-to-bits (stdlib.math.f64-log 1.0)) (cast 0 : u64))
      (=
        (stdlib.math.f32-to-bits
          (stdlib.math.f32-log (stdlib.math.f32-from-bits (cast 0 : u32))))
        (cast 0xff800000 : u32)))
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