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
    (if (> n 1023)
      (begin
        (set! y (* y 8.9884656743115795e+307))
        (set! n (- n 1023))
        (when
          (> n 1023)
          (set! y (* y 8.9884656743115795e+307))
          (set! n (- n 1023))
          (if (> n 1023)
            (set! n 1023)
            unit)))
      (when
        (< n -1022)
        (set! y (* y 2.0041683600089728e-292))
        (set! n (+ n 969))
        (when
          (< n -1022)
          (set! y (* y 2.0041683600089728e-292))
          (set! n (+ n 969))
          (if (< n -1022)
            (set! n -1022)
            unit))))
    (* y (stdlib.math.f64-from-bits (shl (cast (+ 1023 n) : u64) 52)))))

;: Binary32 `scalbn`, following musl `scalbnf` at revision
;: `b306b16af15c89a04d8e0c55cac2dadbeb39c083`.
(define (f32-scalbn [value : f32] [exponent : i64]) : f32
  (let
    [y : f32 value]
    [n : i64 exponent]
    (if (> n 127)
      (begin
        (set! y (* y (cast 1.7014118346046923e+38 : f32)))
        (set! n (- n 127))
        (when
          (> n 127)
          (set! y (* y (cast 1.7014118346046923e+38 : f32)))
          (set! n (- n 127))
          (if (> n 127)
            (set! n 127)
            unit)))
      (when
        (< n -126)
        (set! y (* y (cast 1.9721522630525295e-31 : f32)))
        (set! n (+ n 102))
        (when
          (< n -126)
          (set! y (* y (cast 1.9721522630525295e-31 : f32)))
          (set! n (+ n 102))
          (if (< n -126)
            (set! n -126)
            unit))))
    (* y (stdlib.math.f32-from-bits (shl (cast (+ 127 n) : u32) 23)))))

;: A table word must stay literal so its array needs no startup initializer.
(defmacro (math-bits-word [value : comptime.Expr]) : comptime.Expr
  (match value
    [(comptime.Expr.Int _) value]
    [_
      (comptime.comptime-error
        "math-bits-array: expected a raw integer word literal")]))

;: Build a scalar data initializer; reject expressions that would allocate it.
(defmacro (math-bits-array [values : comptime.Expr ...]) : comptime.Expr
  (let
    [words : comptime.ExprList (comptime.expr-list-empty)]
    [index : i64 (- (comptime.expr-list-length values) 1)]
    (while (>= index 0)
      (set!
        words
        (comptime.expr-list-cons
          `(stdlib.math.math-bits-word ,(comptime.expr-list-nth values index))
          words))
      (set! index (- index 1)))
    `(array ,@words)))

;; The exponential implementation below follows musl `exp`/`expf` and their
;; data tables at revision b306b16af15c89a04d8e0c55cac2dadbeb39c083.
;; Read-only scalar arrays retain the exact IEEE-754 and scale words without
;; startup allocation or aggregate entry results. Binary32 reuses every fourth
;; scale. Payloads and operation order are part of the stated error bounds.
;: Exact tail payloads and adjusted scale words from musl exp_data.c.
(define math-exp-f64-tail-bits : (Array u64 128)
  (math-bits-array
    0x0000000000000000
    0x3c9b3b4f1a88bf6e
    0xbc7160139cd8dc5d
    0xbc905e7a108766d1
    0x3c8cd2523567f613
    0xbc8bce8023f98efa
    0x3c60f74e61e6c861
    0x3c90a3e45b33d399
    0x3c979aa65d837b6d
    0x3c8eb51a92fdeffc
    0x3c3ebe3d702f9cd1
    0xbc6a033489906e0b
    0xbc9556522a2fbd0e
    0xbc5080ef8c4eea55
    0xbc91c923b9d5f416
    0x3c80d3e3e95c55af
    0xbc801b15eaa59348
    0xbc8f1ff055de323d
    0x3c8b898c3f1353bf
    0xbc96d99c7611eb26
    0x3c9aecf73e3a2f60
    0xbc8fe782cb86389d
    0x3c8a6f4144a6c38d
    0x3c807a05b0e4047d
    0x3c968efde3a8a894
    0x3c875e18f274487d
    0x3c80472b981fe7f2
    0xbc96b87b3f71085e
    0x3c82f7e16d09ab31
    0xbc3d219b1a6fbffa
    0x3c8b3782720c0ab4
    0x3c6e149289cecb8f
    0x3c834d754db0abb6
    0x3c864201e2ac744c
    0x3c8fdd395dd3f84a
    0xbc86a3803b8e5b04
    0xbc924aedcc4b5068
    0xbc9907f81b512d8e
    0xbc71d1e83e9436d2
    0xbc991919b3ce1b15
    0x3c859f48a72a4c6d
    0xbc9312607a28698a
    0xbc58a78f4817895b
    0xbc7c2c9b67499a1b
    0x3c4363ed60c2ac11
    0x3c9666093b0664ef
    0x3c6ecce1daa10379
    0x3c93ff8e3f0f1230
    0x3c7690cebb7aafb0
    0x3c931dbdeb54e077
    0xbc8f94340071a38e
    0xbc87deccdc93a349
    0xbc78dec6bd0f385f
    0xbc861246ec7b5cf6
    0x3c93350518fdd78e
    0x3c7b98b72f8a9b05
    0x3c9063e1e21c5409
    0x3c34c7855019c6ea
    0x3c9432e62b64c035
    0xbc8ce44a6199769f
    0xbc8c33c53bef4da8
    0xbc845378892be9ae
    0xbc93cedd78565858
    0x3c5710aa807e1964
    0xbc93b3efbf5e2228
    0xbc6a12ad8734b982
    0xbc6367efb86da9ee
    0xbc80dc3d54e08851
    0xbc781f647e5a3ecf
    0xbc86ee4ac08b7db0
    0xbc8619321e55e68a
    0x3c909ccb5e09d4d3
    0xbc7b32dcb94da51d
    0x3c94ecfd5467c06b
    0x3c65ebe1abd66c55
    0xbc88a1c52fb3cf42
    0xbc9369b6f13b3734
    0xbc805e843a19ff1e
    0xbc94d450d872576e
    0x3c90ad675b0e8a00
    0x3c8db72fc1f0eab4
    0xbc65b6609cc5e7ff
    0x3c7bf68359f35f44
    0xbc93091fa71e3d83
    0xbc5da9b88b6c1e29
    0xbc6c23f97c90b959
    0xbc92434322f4f9aa
    0xbc85ca6cd7668e4b
    0x3c71affc2b91ce27
    0x3c6dd235e10a73bb
    0xbc87c50422622263
    0x3c8b1c86e3e231d5
    0xbc91bbd1d3bcbb15
    0x3c90cc319cee31d2
    0x3c8469846e735ab3
    0xbc82dfcd978e9db4
    0x3c8c1a7792cb3387
    0xbc907b8f4ad1d9fa
    0xbc55c3d956dcaeba
    0xbc90a40e3da6f640
    0xbc68d6f438ad9334
    0xbc91eee26b588a35
    0x3c74ffd70a5fddcd
    0xbc91bdfbfa9298ac
    0x3c736eae30af0cb3
    0x3c8ee3325c9ffd94
    0x3c84e08fd10959ac
    0x3c63cdaf384e1a67
    0x3c676b2c6c921968
    0xbc808a1883ccb5d2
    0xbc8fad5d3ffffa6f
    0xbc900dae3875a949
    0x3c74a385a63d07a7
    0xbc82919e2040220f
    0x3c8e5a50d5c192ac
    0x3c843a59ac016b4b
    0xbc82d52107b43e1f
    0xbc892ab93b470dc9
    0x3c74b604603a88d3
    0x3c83c5ec519d7271
    0xbc8ff7128fd391f0
    0xbc8dae98e223747d
    0x3c8ec3bc41aa2008
    0x3c842b94c3a9eb32
    0x3c8a64a931d185ee
    0xbc8e37bae43be3ed
    0x3c77893b4d91cd9d
    0x3c5305c14160cc89))
(define math-exp-f64-scale-bits : (Array u64 128)
  (math-bits-array
    0x3ff0000000000000
    0x3feff63da9fb3335
    0x3fefec9a3e778061
    0x3fefe315e86e7f85
    0x3fefd9b0d3158574
    0x3fefd06b29ddf6de
    0x3fefc74518759bc8
    0x3fefbe3ecac6f383
    0x3fefb5586cf9890f
    0x3fefac922b7247f7
    0x3fefa3ec32d3d1a2
    0x3fef9b66affed31b
    0x3fef9301d0125b51
    0x3fef8abdc06c31cc
    0x3fef829aaea92de0
    0x3fef7a98c8a58e51
    0x3fef72b83c7d517b
    0x3fef6af9388c8dea
    0x3fef635beb6fcb75
    0x3fef5be084045cd4
    0x3fef54873168b9aa
    0x3fef4d5022fcd91d
    0x3fef463b88628cd6
    0x3fef3f49917ddc96
    0x3fef387a6e756238
    0x3fef31ce4fb2a63f
    0x3fef2b4565e27cdd
    0x3fef24dfe1f56381
    0x3fef1e9df51fdee1
    0x3fef187fd0dad990
    0x3fef1285a6e4030b
    0x3fef0cafa93e2f56
    0x3fef06fe0a31b715
    0x3fef0170fc4cd831
    0x3feefc08b26416ff
    0x3feef6c55f929ff1
    0x3feef1a7373aa9cb
    0x3feeecae6d05d866
    0x3feee7db34e59ff7
    0x3feee32dc313a8e5
    0x3feedea64c123422
    0x3feeda4504ac801c
    0x3feed60a21f72e2a
    0x3feed1f5d950a897
    0x3feece086061892d
    0x3feeca41ed1d0057
    0x3feec6a2b5c13cd0
    0x3feec32af0d7d3de
    0x3feebfdad5362a27
    0x3feebcb299fddd0d
    0x3feeb9b2769d2ca7
    0x3feeb6daa2cf6642
    0x3feeb42b569d4f82
    0x3feeb1a4ca5d920f
    0x3feeaf4736b527da
    0x3feead12d497c7fd
    0x3feeab07dd485429
    0x3feea9268a5946b7
    0x3feea76f15ad2148
    0x3feea5e1b976dc09
    0x3feea47eb03a5585
    0x3feea34634ccc320
    0x3feea23882552225
    0x3feea155d44ca973
    0x3feea09e667f3bcd
    0x3feea012750bdabf
    0x3fee9fb23c651a2f
    0x3fee9f7df9519484
    0x3fee9f75e8ec5f74
    0x3fee9f9a48a58174
    0x3fee9feb564267c9
    0x3feea0694fde5d3f
    0x3feea11473eb0187
    0x3feea1ed0130c132
    0x3feea2f336cf4e62
    0x3feea427543e1a12
    0x3feea589994cce13
    0x3feea71a4623c7ad
    0x3feea8d99b4492ed
    0x3feeaac7d98a6699
    0x3feeace5422aa0db
    0x3feeaf3216b5448c
    0x3feeb1ae99157736
    0x3feeb45b0b91ffc6
    0x3feeb737b0cdc5e5
    0x3feeba44cbc8520f
    0x3feebd829fde4e50
    0x3feec0f170ca07ba
    0x3feec49182a3f090
    0x3feec86319e32323
    0x3feecc667b5de565
    0x3feed09bec4a2d33
    0x3feed503b23e255d
    0x3feed99e1330b358
    0x3feede6b5579fdbf
    0x3feee36bbfd3f37a
    0x3feee89f995ad3ad
    0x3feeee07298db666
    0x3feef3a2b84f15fb
    0x3feef9728de5593a
    0x3feeff76f2fb5e47
    0x3fef05b030a1064a
    0x3fef0c1e904bc1d2
    0x3fef12c25bd71e09
    0x3fef199bdd85529c
    0x3fef20ab5fffd07a
    0x3fef27f12e57d14b
    0x3fef2f6d9406e7b5
    0x3fef3720dcef9069
    0x3fef3f0b555dc3fa
    0x3fef472d4a07897c
    0x3fef4f87080d89f2
    0x3fef5818dcfba487
    0x3fef60e316c98398
    0x3fef69e603db3285
    0x3fef7321f301b460
    0x3fef7c97337b9b5f
    0x3fef864614f5a129
    0x3fef902ee78b3ff6
    0x3fef9a51fbc74c83
    0x3fefa4afa2a490da
    0x3fefaf482d8e67f1
    0x3fefba1bee615a27
    0x3fefc52b376bba97
    0x3fefd0765b6e4540
    0x3fefdbfdad9cbe14
    0x3fefe7c1819e90d8
    0x3feff3c22b8f71f1))

;: Complete a binary64 result whose table scale may overflow or underflow.
(define (math-exp-f64-special [tmp : f64] [scale-bits : u64] [k-bits : u64]) : f64
  (if (= (bit-and k-bits (cast 0x80000000 : u64)) (cast 0 : u64))
    (let
      [adjusted-bits : u64 (- scale-bits (shl (cast 1009 : u64) 52))]
      [scale : f64 (stdlib.math.f64-from-bits adjusted-bits)]
      (* 5.4861240687936887e+303 (+ scale (* scale tmp))))
    (let
      [adjusted-bits : u64 (+ scale-bits (shl (cast 1022 : u64) 52))]
      [scale : f64 (stdlib.math.f64-from-bits adjusted-bits)]
      [y : f64 (+ scale (* scale tmp))]
      (if (< y 1.0)
        (let
          [lo : f64 (+ (- scale y) (* scale tmp))]
          [hi : f64 (+ 1.0 y)]
          (set! lo (+ (+ (- 1.0 hi) y) lo))
          (set! y (- (+ hi lo) 1.0)))
        unit)
      (* 2.2250738585072014e-308 y))))

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
          [z : f64 (* 184.66496523378731 value)]
          [rounded : f64 (+ z 6755399441055744.0)]
          [k-bits : u64 (stdlib.math.f64-to-bits rounded)]
          [k : f64 (- rounded 6755399441055744.0)]
          [r : f64
            (+
              (+ value (* k -0.0054152123481117087))
              (* k -1.2864023111638346e-14))]
          [index : i64 (cast (bit-and k-bits (cast 127 : u64)) : i64)]
          [scale-bits : u64
            (+ (array-ref math-exp-f64-scale-bits index) (shl k-bits 45))]
          [tail : f64
            (stdlib.math.f64-from-bits (array-ref math-exp-f64-tail-bits index))]
          [r2 : f64 (* r r)]
          [tmp : f64
            (+
              (+
                (+ tail r)
                (* r2 (+ 0.49999999999996786 (* r 0.16666666666665886))))
              (* (* r2 r2) (+ 0.041666680841067401 (* r 0.0083333358530595491))))]
          (if (>= magnitude-top (cast 0x408 : u64))
            (math-exp-f64-special tmp scale-bits k-bits)
            (let
              [scale : f64 (stdlib.math.f64-from-bits scale-bits)]
              (+ scale (* scale tmp)))))))))

;: Evaluate the finite, non-extreme binary32 exponential reduction.
(define (math-exp-f32-finite [value : f32]) : f32
  (let
    [x : f64 (cast value : f64)]
    [z : f64 (* 46.166241308446828 x)]
    [rounded : f64 (+ z 6755399441055744.0)]
    [k-bits : u64 (stdlib.math.f64-to-bits rounded)]
    [k : f64 (- rounded 6755399441055744.0)]
    [r : f64 (- z k)]
    [index : i64 (* (cast (bit-and k-bits (cast 31 : u64)) : i64) 4)]
    [scale-bits : u64
      (+ (array-ref math-exp-f64-scale-bits index) (shl k-bits 47))]
    [scale : f64 (stdlib.math.f64-from-bits scale-bits)]
    [p : f64 (+ (* 1.6938359250920212e-06 r) 0.00023459809789509004)]
    [r2 : f64 (* r r)]
    [y : f64 (+ (* 0.021660849396613134 r) 1.0)]
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
        [(> value (cast 88.722831726074219 : f32))
          (stdlib.math.f32-positive-infinity)]
        [(< value (cast -103.97207641601562 : f32)) (cast 0.0 : f32)]
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
;; Per-field arrays retain exact IEEE-754 u64 payloads. Reduction order
;; remains fixed, including the separate head and tail compensation.
;: Exact binary64 logarithm interval payloads from musl log_data.c.
(define math-log-f64-invc-bits : (Array u64 128)
  (math-bits-array
    0x3ff734f0c3e0de9f
    0x3ff713786a2ce91f
    0x3ff6f26008fab5a0
    0x3ff6d1a61f138c7d
    0x3ff6b1490bc5b4d1
    0x3ff69147332f0cba
    0x3ff6719f18224223
    0x3ff6524f99a51ed9
    0x3ff63356aa8f24c4
    0x3ff614b36b9ddc14
    0x3ff5f66452c65c4c
    0x3ff5d867b5912c4f
    0x3ff5babccb5b90de
    0x3ff59d61f2d91a78
    0x3ff5805612465687
    0x3ff56397cee76bd3
    0x3ff54725e2a77f93
    0x3ff52aff42064583
    0x3ff50f22dbb2bddf
    0x3ff4f38f4734ded7
    0x3ff4d843cfde2840
    0x3ff4bd3ec078a3c8
    0x3ff4a27fc3e0258a
    0x3ff4880524d48434
    0x3ff46dce1b192d0b
    0x3ff453d9d3391854
    0x3ff43a2744b4845a
    0x3ff420b54115f8fb
    0x3ff40782da3ef4b1
    0x3ff3ee8f5d57fe8f
    0x3ff3d5d9a00b4ce9
    0x3ff3bd60c010c12b
    0x3ff3a5242b75dab8
    0x3ff38d22cd9fd002
    0x3ff3755bc5847a1c
    0x3ff35dce49ad36e2
    0x3ff34679984dd440
    0x3ff32f5cceffcb24
    0x3ff3187775a10d49
    0x3ff301c8373e3990
    0x3ff2eb4ebb95f841
    0x3ff2d50a0219a9d1
    0x3ff2bef9a8b7fd2a
    0x3ff2a91c7a0c1bab
    0x3ff293726014b530
    0x3ff27dfa5757a1f5
    0x3ff268b39b1d3bbf
    0x3ff2539d838ff5bd
    0x3ff23eb7aac9083b
    0x3ff22a012ba940b6
    0x3ff2157996cc4132
    0x3ff201201dd2fc9b
    0x3ff1ecf4494d480b
    0x3ff1d8f5528f6569
    0x3ff1c52311577e7c
    0x3ff1b17c74cb26e9
    0x3ff19e010c2c1ab6
    0x3ff18ab07bb670bd
    0x3ff1778a25efbcb6
    0x3ff1648d354c31da
    0x3ff151b990275fdd
    0x3ff13f0ea432d24c
    0x3ff12c8b7210f9da
    0x3ff11a3028ecb531
    0x3ff107fbda8434af
    0x3ff0f5ee0f4e6bb3
    0x3ff0e4065d2a9fce
    0x3ff0d244632ca521
    0x3ff0c0a77ce2981a
    0x3ff0af2f83c636d1
    0x3ff09ddb98a01339
    0x3ff08cabaf52e7df
    0x3ff07b9f2f4e28fb
    0x3ff06ab58c358f19
    0x3ff059eea5ecf92c
    0x3ff04949cdd12c90
    0x3ff038c6c6f0ada9
    0x3ff02865137932a9
    0x3ff0182427ea7348
    0x3ff008040614b195
    0x3fefe01ff726fa1a
    0x3fefa11cc261ea74
    0x3fef6310b081992e
    0x3fef25f63ceeadcd
    0x3feee9c8039113e7
    0x3feeae8078cbb1ab
    0x3fee741aa29d0c9b
    0x3fee3a91830a99b5
    0x3fee01e009609a56
    0x3fedca01e577bb98
    0x3fed92f20b7c9103
    0x3fed5cac66fb5cce
    0x3fed272caa5ede9d
    0x3fecf26e3e6b2ccd
    0x3fecbe6da2a77902
    0x3fec8b266d37086d
    0x3fec5894bd5d5804
    0x3fec26b533bb9f8c
    0x3febf583eeece73f
    0x3febc4fd75db96c1
    0x3feb951e0c864a28
    0x3feb65e2c5ef3e2c
    0x3feb374867c9888b
    0x3feb094b211d304a
    0x3feadbe885f2ef7e
    0x3feaaf1d31603da2
    0x3fea82e63fd358a7
    0x3fea5740ef09738b
    0x3fea2c2a90ab4b27
    0x3fea01a01393f2d1
    0x3fe9d79f24db3c1b
    0x3fe9ae2505c7b190
    0x3fe9852ef297ce2f
    0x3fe95cbaeea44b75
    0x3fe934c69de74838
    0x3fe90d4f2f6752e6
    0x3fe8e6528effd79d
    0x3fe8bfce9fcc007c
    0x3fe899c0dabec30e
    0x3fe87427aa2317fb
    0x3fe84f00acb39a08
    0x3fe82a49e8653e55
    0x3fe8060195f40260
    0x3fe7e22563e0a329
    0x3fe7beb377dcb5ad
    0x3fe79baa679725c2
    0x3fe77907f2170657
    0x3fe756cadbd6130c))
(define math-log-f64-logc-bits : (Array u64 128)
  (math-bits-array
    0xbfd7cc7f79e69000
    0xbfd76feec20d0000
    0xbfd713e31351e000
    0xbfd6b85b38287800
    0xbfd65d5590807800
    0xbfd602d076180000
    0xbfd5a8ca86909000
    0xbfd54f4356035000
    0xbfd4f637c36b4000
    0xbfd49da7fda85000
    0xbfd445923989a800
    0xbfd3edf439b0b800
    0xbfd396ce448f7000
    0xbfd3401e17bda000
    0xbfd2e9e2ef468000
    0xbfd2941b3830e000
    0xbfd23ec58cda8800
    0xbfd1e9e129279000
    0xbfd1956d2b48f800
    0xbfd141679ab9f800
    0xbfd0edd094ef9800
    0xbfd09aa518db1000
    0xbfd047e65263b800
    0xbfcfeb224586f000
    0xbfcf474a7517b000
    0xbfcea4443d103000
    0xbfce020d44e9b000
    0xbfcd60a22977f000
    0xbfccc00104959000
    0xbfcc202956891000
    0xbfcb81178d811000
    0xbfcae2c9ccd3d000
    0xbfca45402e129000
    0xbfc9a877681df000
    0xbfc90c6d69483000
    0xbfc87120a645c000
    0xbfc7d68fb4143000
    0xbfc73cb83c627000
    0xbfc6a39a9b376000
    0xbfc60b3154b7a000
    0xbfc5737d76243000
    0xbfc4dc7b8fc23000
    0xbfc4462c51d20000
    0xbfc3b08abc830000
    0xbfc31b996b490000
    0xbfc2875490a44000
    0xbfc1f3b9f879a000
    0xbfc160c8252ca000
    0xbfc0ce7f57f72000
    0xbfc03cdc49fea000
    0xbfbf57bdbc4b8000
    0xbfbe370896404000
    0xbfbd17983ef94000
    0xbfbbf9674ed8a000
    0xbfbadc79202f6000
    0xbfb9c0c3e7288000
    0xbfb8a646b372c000
    0xbfb78d01b3ac0000
    0xbfb674f145380000
    0xbfb55e0e6d878000
    0xbfb4485cdea1e000
    0xbfb333d94d6aa000
    0xbfb22079f8c56000
    0xbfb10e4698622000
    0xbfaffa6c6ad20000
    0xbfadda8d4a774000
    0xbfabbcece4850000
    0xbfa9a1894012c000
    0xbfa788583302c000
    0xbfa5715e67d68000
    0xbfa35c8a49658000
    0xbfa149e364154000
    0xbf9e72c082eb8000
    0xbf9a55f152528000
    0xbf963d62cf818000
    0xbf9228fb8caa0000
    0xbf8c317b20f90000
    0xbf8419355daa0000
    0xbf781203c2ec0000
    0xbf60040979240000
    0x3f6feff384900000
    0x3f87dc41353d0000
    0x3f93cea3c4c28000
    0x3f9b9fc114890000
    0x3fa1b0d8ce110000
    0x3fa58a5bd001c000
    0x3fa95c8340d88000
    0x3fad276aef578000
    0x3fb07598e598c000
    0x3fb253f5e30d2000
    0x3fb42edd8b380000
    0x3fb606598757c000
    0x3fb7da76356a0000
    0x3fb9ab434e1c6000
    0x3fbb78c7bb0d6000
    0x3fbd431332e72000
    0x3fbf0a3171de6000
    0x3fc067152b914000
    0x3fc147858292b000
    0x3fc2266ecdca3000
    0x3fc303d7a6c55000
    0x3fc3dfc33c331000
    0x3fc4ba366b7a8000
    0x3fc5933928d1f000
    0x3fc66acd2418f000
    0x3fc740f8ec669000
    0x3fc815c0f51af000
    0x3fc8e92954f68000
    0x3fc9bb3602f84000
    0x3fca8bed1c2c0000
    0x3fcb5b515c01d000
    0x3fcc2967ccbcc000
    0x3fccf635d5486000
    0x3fcdc1bd3446c000
    0x3fce8c01b8cfe000
    0x3fcf5509c0179000
    0x3fd00e6c121fb800
    0x3fd071b80e93d000
    0x3fd0d46b9e867000
    0x3fd13687334bd000
    0x3fd1980d67234800
    0x3fd1f8ffe0cc8000
    0x3fd2595fd7636800
    0x3fd2b9300914a800
    0x3fd3187210436000
    0x3fd377266dec1800
    0x3fd3d54ffbaf3000
    0x3fd432eee32fe000))
(define math-log-f64-chi-bits : (Array u64 128)
  (math-bits-array
    0x3fe61000014fb66b
    0x3fe63000034db495
    0x3fe650000d94d478
    0x3fe67000074e6fad
    0x3fe68ffffedf0fae
    0x3fe6b0000763c5bc
    0x3fe6d0001e5cc1f6
    0x3fe6efffeb05f63e
    0x3fe710000e869780
    0x3fe72ffffc67e912
    0x3fe74fffdf81116a
    0x3fe770000f679c90
    0x3fe78ffffa7ec835
    0x3fe7affffe20c2e6
    0x3fe7cfffed3fc900
    0x3fe7efffe9261a76
    0x3fe81000049ca3e8
    0x3fe8300017932c8f
    0x3fe850000633739c
    0x3fe87000204289c6
    0x3fe88fffebf57904
    0x3fe8b00022bc04df
    0x3fe8cfffe50c1b8a
    0x3fe8effffc918e43
    0x3fe910001efa5fc7
    0x3fe9300013467bb9
    0x3fe94fffe6ee076f
    0x3fe96fffde3c12d1
    0x3fe98ffff4458a0d
    0x3fe9afffdd982e3e
    0x3fe9cfffed49fb66
    0x3fe9f00020f19c51
    0x3fea10001145b006
    0x3fea300007bbf6fa
    0x3fea500010971d79
    0x3fea70001df52e48
    0x3fea90001c593352
    0x3feab0002a4f3e4b
    0x3feacfffd7ae1ed1
    0x3feaefffee510478
    0x3feb0fffdb650d5b
    0x3feb2ffffeaaca57
    0x3feb4fffd995badc
    0x3feb7000249e659c
    0x3feb8ffff9871640
    0x3febafffd204cb4f
    0x3febcfffd2415c45
    0x3febeffff86309df
    0x3fec0fffe1b57653
    0x3fec2ffff1fa57e3
    0x3fec4fffdcbfe424
    0x3fec6fffed54b9f7
    0x3fec8fffeb998fd5
    0x3fecb0002125219a
    0x3feccfffdd94469c
    0x3fecefffeafdc476
    0x3fed1000169af82b
    0x3fed30000d0ff71d
    0x3fed4fffea790fc4
    0x3fed70002edc87e5
    0x3fed900021dc82aa
    0x3fedafffd86b0283
    0x3fedd000296c4739
    0x3fedefffe54490f5
    0x3fee0fffcdabf694
    0x3fee2fffdb52c8dd
    0x3fee4ffff24216ef
    0x3fee6fffe88a5e11
    0x3fee9000119eff0d
    0x3feeafffdfa51744
    0x3feed0001a127fa1
    0x3feef00007babcc4
    0x3fef0ffff57a8d02
    0x3fef30001ee58ac7
    0x3fef4ffff5823494
    0x3fef6ffffca94c6b
    0x3fef8fffe1f9c441
    0x3fefafffd2e0e37e
    0x3fefd0001c77e49e
    0x3fefeffff7e0c331
    0x3ff00ffff465606e
    0x3ff02ffff3867a58
    0x3ff04ffffdfc0d17
    0x3ff0700003cd4d82
    0x3ff08ffff9f2cbe8
    0x3ff0b000010cda65
    0x3ff0d00001a4d338
    0x3ff0effffadafdfd
    0x3ff110000bbafd96
    0x3ff12ffffae5f45d
    0x3ff150000dd59ad9
    0x3ff170000f21559a
    0x3ff18ffffc275426
    0x3ff1b000123d3c59
    0x3ff1cffff8299eb7
    0x3ff1effff48ad400
    0x3ff210000c8b86a4
    0x3ff2300003854303
    0x3ff24fffffbcf684
    0x3ff26ffff52921d9
    0x3ff2900014933a3c
    0x3ff2b00014556313
    0x3ff2cfffebfe523b
    0x3ff2f0000bb8ad96
    0x3ff30ffffb7ae2af
    0x3ff32ffffeac5f7f
    0x3ff350000ca66756
    0x3ff3700011fbf721
    0x3ff38ffff9592fb9
    0x3ff3b00004ddd242
    0x3ff3cffff5b2c957
    0x3ff3efffeab0b418
    0x3ff410001532aff4
    0x3ff4300017478b29
    0x3ff44fffe795b463
    0x3ff46fffe80475e0
    0x3ff48fffef6fc1e7
    0x3ff4afffe5bea704
    0x3ff4d000171027de
    0x3ff4f0000ff03ee2
    0x3ff5100012dc4bd1
    0x3ff530001605277a
    0x3ff54fffecdb704c
    0x3ff56fffef5f54a9
    0x3ff5900017e61012
    0x3ff5b00003c93e92
    0x3ff5d0001d4919bc
    0x3ff5efffe7b87a89))
(define math-log-f64-clo-bits : (Array u64 128)
  (math-bits-array
    0x3c7e026c91425b3c
    0x3c8dbfea48005d41
    0x3c8e7fa786d6a5b7
    0x3c61fcea6b54254c
    0xbc7c7e274c590efd
    0xbc8ac16848dcda01
    0x3c833f1c9d499311
    0xbc7e80041ae22d53
    0x3c7bff6671097952
    0x3c8c00e226bd8724
    0xbc6e02916ef101d2
    0xbc67fc71cd549c74
    0x3c81bec19ef50483
    0xbc707e1729cc6465
    0xbc808072087b8b1c
    0x3c8dc0286d9df9ae
    0x3c897fd251e54c33
    0xbc8afee9b630f381
    0x3c89bfbf6b6535bc
    0xbc8bbf65f3117b75
    0xbc89006ea23dcb57
    0xbc7d00df38e04b0a
    0xbc88007146ff9f05
    0x3c83817bd07a7038
    0x3c893e9176dfb403
    0x3c7f804e4b980276
    0xbc8f7ef0d9ff622e
    0xbc7082aa962638ba
    0xbc87801b9164a8ef
    0xbc8740e08a5a9337
    0x3c3fce08c19be000
    0xbc8a3faa27885b0a
    0x3c74ff489958da56
    0x3c8cbeab8a2b6d18
    0x3c88fecadd787930
    0xbc8f41763dd8abdb
    0xbc8ebf0284c27612
    0xbc69fd043cff3f5f
    0xbc823ee7129070b4
    0x3c6a063ee00edea3
    0x3c5a06c8381f0ab9
    0xbc79011e74233c1d
    0xbc79ff1068862a9f
    0x3c8aff45d0864f3e
    0x3c7cfe7796c2c3f9
    0xbc63ff27eef22bc4
    0xbc6cffb7ee3bea21
    0xbc814103972e0b5c
    0x3c8bc16494b76a19
    0xbc64feef8d30c6ed
    0xbc843f68bcec4775
    0x3c847ea3f053e0ec
    0x3c7383068df992f1
    0xbc68fd8e64180e04
    0x3c8e7ebe1cc7ea72
    0x3c8ebe39ad9f88fe
    0x3c757d91a8b95a71
    0x3c89c1906970c7da
    0xbc580e37c558fe0c
    0xbc7f80d64dc10f44
    0xbc747c8f94fd5c5c
    0x3c8c7f1dc521617e
    0x3c88019eb2ffb153
    0x3c6e00d2c652cc89
    0xbc7f8340202d69d2
    0x3c7b00c1ca1b0864
    0x3c72ffa8b094ab51
    0xbc57f673b1efbe59
    0xbc84808d5e0bc801
    0x3c780006d54320b5
    0xbc5002f860565c92
    0xbc8540445d35e611
    0xbc4ffb3139ef9105
    0x3c8a81acf2731155
    0x3c8a3f41d4d7c743
    0xbc6202f41c987875
    0x3c777dd1f477e74b
    0xbc6f01199a7ca331
    0x3c7181ee4bceacb1
    0xbc6e05370170875a
    0xbc8a7ead491c0ada
    0xbc977f69c3fcb2e0
    0x3c97bffe34cb945b
    0x3c820083c0e456cb
    0xbc6dffdfbe37751a
    0xbc913f7faee626eb
    0x3c807dfa79489ff7
    0xbc77040570d66bc0
    0x3c8e80d4846d0b62
    0x3c9dbffa64fd36ef
    0x3c9a0077701250ae
    0x3c8dfdf9e2e3deee
    0x3c910030dc3b7273
    0x3c997f7980030188
    0xbc65f932ab9f8c67
    0x3c937fbf9da75beb
    0x3c9f806b91fd5b22
    0x3c93ffc2eb9fbf33
    0x3c7601e77e2e2e72
    0x3c7ffcbb767f0c61
    0xbc7202ca3c02412b
    0xbc92808233f21f02
    0xbc88ff7e384fdcf2
    0xbc85ff51503041c5
    0xbc810071885e289d
    0xbc91ff5d3fb7b715
    0x3c957f82228b82bd
    0x3c8000bac40dd5cc
    0xbc943f9d2db2a751
    0x3c857f6b707638e1
    0x3c7a023a10bf1231
    0x3c987f6d66b152b0
    0x3c67f8375f198524
    0x3c8301e672dc5143
    0x3c89ff69b8b2895a
    0xbc95c0b19bc2f254
    0x3c9b4009f23a2a72
    0xbc94ffb7bf0d7d45
    0xbc99c06471dc6a3d
    0x3c977f890b85531c
    0x3c6004657166a436
    0xbc96bfcece233209
    0xbc8902720505a1d7
    0x3c9bbfe60ec96412
    0x3c887ec581afef90
    0xbc9f41080abf0cc0
    0xbc98812afb254729
    0xbc947eb780ed6904))

;: Exact binary32 logarithm interval payloads, evaluated as binary64.
(define math-log-f32-invc-bits : (Array u64 16)
  (math-bits-array
    0x3ff661ec79f8f3be
    0x3ff571ed4aaf883d
    0x3ff49539f0f010b0
    0x3ff3c995b0b80385
    0x3ff30d190c8864a5
    0x3ff25e227b0b8ea0
    0x3ff1bb4a4a1a343f
    0x3ff12358f08ae5ba
    0x3ff0953f419900a7
    0x3ff0000000000000
    0x3fee608cfd9a47ac
    0x3feca4b31f026aa0
    0x3feb2036576afce6
    0x3fe9c2d163a1aa2d
    0x3fe886e6037841ed
    0x3fe767dcf5534862))
(define math-log-f32-logc-bits : (Array u64 16)
  (math-bits-array
    0xbfd57bf7808caade
    0xbfd2bef0a7c06ddb
    0xbfd01eae7f513a67
    0xbfcb31d8a68224e9
    0xbfc6574f0ac07758
    0xbfc1aa2bc79c8100
    0xbfba4e76ce8c0e5e
    0xbfb1973c5a611ccc
    0xbfa252f438e10c1e
    0x0000000000000000
    0x3faaa5aa5df25984
    0x3fbc5e53aa362eb4
    0x3fc526e57720db08
    0x3fcbc2860d224770
    0x3fd1058bc8a07ee1
    0x3fd4043057b6ee09))

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
            (+ 0.3333333333333352 (* r -0.24999999999998432))
            (* r2 0.19999999999320328))
          (*
            r3
            (+
              (+
                (+ -0.16666666669929706 (* r 0.14285715076560868))
                (* r2 -0.12499997863982555))
              (*
                r3
                (+
                  (+
                    (+ 0.11110712032936046 (* r -0.10000486757818193))
                    (* r2 0.091819940061954666))
                  (* r3 -0.083283630622893415)))))))]
    [split : f64 (* r 134217728.0)]
    [rhi : f64 (- (+ r split) split)]
    [rlo : f64 (- r rhi)]
    [w : f64 (* (* rhi rhi) -0.5)]
    [hi : f64 (+ r w)]
    [lo : f64 (+ (- r hi) w)]
    (set! lo (+ lo (* (* -0.5 rlo) (+ rhi r))))
    (set! y (+ y lo))
    (+ y hi)))

;: Evaluate the ordinary binary64 logarithm table reduction.
(define (math-log-f64-finite [bits : u64]) : f64
  (let
    [normalized-bits : u64
      (if (< bits (cast 0x0010000000000000 : u64))
        (-
          (stdlib.math.f64-to-bits
            (* (stdlib.math.f64-from-bits bits) 4503599627370496.0))
          (shl (cast 52 : u64) 52))
        bits)]
    [tmp : u64 (- normalized-bits (cast 0x3fe6000000000000 : u64))]
    [index : i64 (cast (bit-and (shr tmp 45) (cast 127 : u64)) : i64)]
    [k : i64 (shr (cast tmp : i64) 52)]
    [reduced-bits : u64
      (- normalized-bits (bit-and tmp (cast 0xfff0000000000000 : u64)))]
    [invc : f64
      (stdlib.math.f64-from-bits (array-ref math-log-f64-invc-bits index))]
    [logc : f64
      (stdlib.math.f64-from-bits (array-ref math-log-f64-logc-bits index))]
    [chi : f64
      (stdlib.math.f64-from-bits (array-ref math-log-f64-chi-bits index))]
    [clo : f64
      (stdlib.math.f64-from-bits (array-ref math-log-f64-clo-bits index))]
    [z : f64 (stdlib.math.f64-from-bits reduced-bits)]
    [r : f64 (* (- (- z chi) clo) invc)]
    [kd : f64 (cast k : f64)]
    [w : f64 (+ (* kd 0.69314718055989033) logc)]
    [hi : f64 (+ w r)]
    [lo : f64 (+ (+ (- w hi) r) (* kd 5.4979230187083712e-14))]
    [r2 : f64 (* r r)]
    (+
      (+
        (+ lo (* r2 -0.50000000000000011))
        (*
          (* r r2)
          (+
            (+ 0.33333333331825593 (* r -0.24999999996229549))
            (* r2 (+ 0.20000304511814496 (* r -0.16667054827627667))))))
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
            (* (stdlib.math.f32-from-bits bits) (cast 8388608.0 : f32)))
          (shl (cast 23 : u32) 23))
        bits)]
    [tmp : u32 (- normalized-bits (cast 0x3f330000 : u32))]
    [index : i64 (cast (bit-and (shr tmp 19) (cast 15 : u32)) : i64)]
    [k : i64 (cast (shr (cast tmp : i32) 23) : i64)]
    [reduced-bits : u32
      (- normalized-bits (bit-and tmp (cast 0xff800000 : u32)))]
    [invc : f64
      (stdlib.math.f64-from-bits (array-ref math-log-f32-invc-bits index))]
    [logc : f64
      (stdlib.math.f64-from-bits (array-ref math-log-f32-logc-bits index))]
    [z : f64 (cast (stdlib.math.f32-from-bits reduced-bits) : f64)]
    [r : f64 (- (* z invc) 1.0)]
    [y0 : f64 (+ logc (* (cast k : f64) 0.69314718055994529))]
    [r2 : f64 (* r r)]
    [y : f64 (+ (* 0.33345676574406602 r) -0.49999974858021029)]
    (set! y (+ (* -0.25089342214237154 r2) y))
    (set! y (+ (* y r2) (+ y0 r)))
    (cast y : f32)))

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

;; The power implementation below follows musl `pow`/`powf` and their data
;; tables at revision b306b16af15c89a04d8e0c55cac2dadbeb39c083 (the Arm
;; optimized-routines algorithm), using the documented non-FMA evaluation
;; paths (HAVE_FAST_FMA unset, TOINT_INTRINSICS unset, EXP_USE_TOINT_NARROW 0,
;; WANT_ERRNO unset, POWF_SCALE 1). Table fields are shortest round-tripping
;; decimal literals folded to exact IEEE-754 payloads through `f64-to-bits`;
;; scalar constants are shortest round-tripping decimal literals, and operation
;; order remains fixed because both are part of the stated error bounds. The
;; fenv/errno-dependent
;; upstream branches collapse to the plain infinity/zero/NaN results:
;; TypeLisp exposes only the default round-to-nearest mode, has no floating
;; point exception flags, and does not quiet or inspect signaling NaNs, so
;; the `WANT_ROUNDING`/`WANT_ERRNO`/`opt_barrier`/`force_eval` machinery and
;; the `issignaling_inline` special cases are outside the contract, mirroring
;; the exp/log ports above.
;: Exact binary64 pow logarithm interval payloads from musl pow_data.c.
(define math-pow-f64-invc-bits : (Array u64 128)
  (math-bits-array
    0x3ff6a00000000000
    0x3ff6800000000000
    0x3ff6600000000000
    0x3ff6400000000000
    0x3ff6200000000000
    0x3ff6000000000000
    0x3ff5e00000000000
    0x3ff5c00000000000
    0x3ff5a00000000000
    0x3ff5800000000000
    0x3ff5600000000000
    0x3ff5600000000000
    0x3ff5400000000000
    0x3ff5200000000000
    0x3ff5000000000000
    0x3ff4e00000000000
    0x3ff4c00000000000
    0x3ff4a00000000000
    0x3ff4a00000000000
    0x3ff4800000000000
    0x3ff4600000000000
    0x3ff4400000000000
    0x3ff4200000000000
    0x3ff4000000000000
    0x3ff4000000000000
    0x3ff3e00000000000
    0x3ff3c00000000000
    0x3ff3a00000000000
    0x3ff3a00000000000
    0x3ff3800000000000
    0x3ff3600000000000
    0x3ff3400000000000
    0x3ff3400000000000
    0x3ff3200000000000
    0x3ff3000000000000
    0x3ff3000000000000
    0x3ff2e00000000000
    0x3ff2c00000000000
    0x3ff2c00000000000
    0x3ff2a00000000000
    0x3ff2800000000000
    0x3ff2600000000000
    0x3ff2600000000000
    0x3ff2400000000000
    0x3ff2400000000000
    0x3ff2200000000000
    0x3ff2000000000000
    0x3ff2000000000000
    0x3ff1e00000000000
    0x3ff1c00000000000
    0x3ff1c00000000000
    0x3ff1a00000000000
    0x3ff1a00000000000
    0x3ff1800000000000
    0x3ff1600000000000
    0x3ff1600000000000
    0x3ff1400000000000
    0x3ff1400000000000
    0x3ff1200000000000
    0x3ff1000000000000
    0x3ff1000000000000
    0x3ff0e00000000000
    0x3ff0e00000000000
    0x3ff0c00000000000
    0x3ff0c00000000000
    0x3ff0a00000000000
    0x3ff0a00000000000
    0x3ff0800000000000
    0x3ff0800000000000
    0x3ff0600000000000
    0x3ff0400000000000
    0x3ff0400000000000
    0x3ff0200000000000
    0x3ff0200000000000
    0x3ff0000000000000
    0x3ff0000000000000
    0x3fefc00000000000
    0x3fef800000000000
    0x3fef400000000000
    0x3fef000000000000
    0x3feec00000000000
    0x3fee800000000000
    0x3fee400000000000
    0x3fee200000000000
    0x3fede00000000000
    0x3feda00000000000
    0x3fed600000000000
    0x3fed400000000000
    0x3fed000000000000
    0x3fecc00000000000
    0x3feca00000000000
    0x3fec600000000000
    0x3fec400000000000
    0x3fec000000000000
    0x3febe00000000000
    0x3feba00000000000
    0x3feb800000000000
    0x3feb400000000000
    0x3feb200000000000
    0x3feae00000000000
    0x3feac00000000000
    0x3feaa00000000000
    0x3fea600000000000
    0x3fea400000000000
    0x3fea000000000000
    0x3fe9e00000000000
    0x3fe9c00000000000
    0x3fe9a00000000000
    0x3fe9600000000000
    0x3fe9400000000000
    0x3fe9200000000000
    0x3fe9000000000000
    0x3fe8c00000000000
    0x3fe8a00000000000
    0x3fe8800000000000
    0x3fe8600000000000
    0x3fe8400000000000
    0x3fe8200000000000
    0x3fe7e00000000000
    0x3fe7c00000000000
    0x3fe7a00000000000
    0x3fe7800000000000
    0x3fe7600000000000
    0x3fe7400000000000
    0x3fe7200000000000
    0x3fe7000000000000
    0x3fe6e00000000000
    0x3fe6c00000000000))
(define math-pow-f64-logc-bits : (Array u64 128)
  (math-bits-array
    0xbfd62c82f2b9c800
    0xbfd5d1bdbf580800
    0xbfd5767717455800
    0xbfd51aad872df800
    0xbfd4be5f95777800
    0xbfd4618bc21c6000
    0xbfd404308686a800
    0xbfd3a64c55694800
    0xbfd347dd9a988000
    0xbfd2e8e2bae12000
    0xbfd2895a13de8800
    0xbfd2895a13de8800
    0xbfd22941fbcf7800
    0xbfd1c898c1699800
    0xbfd1675cababa800
    0xbfd1058bf9ae4800
    0xbfd0a324e2739000
    0xbfd0402594b4d000
    0xbfd0402594b4d000
    0xbfcfb9186d5e4000
    0xbfcef0adcbdc6000
    0xbfce27076e2af000
    0xbfcd5c216b4fc000
    0xbfcc8ff7c79aa000
    0xbfcc8ff7c79aa000
    0xbfcbc286742d9000
    0xbfcaf3c94e80c000
    0xbfca23bc1fe2b000
    0xbfca23bc1fe2b000
    0xbfc9525a9cf45000
    0xbfc87fa06520d000
    0xbfc7ab890210e000
    0xbfc7ab890210e000
    0xbfc6d60fe719d000
    0xbfc5ff3070a79000
    0xbfc5ff3070a79000
    0xbfc526e5e3a1b000
    0xbfc44d2b6ccb8000
    0xbfc44d2b6ccb8000
    0xbfc371fc201e9000
    0xbfc29552f81ff000
    0xbfc1b72ad52f6000
    0xbfc1b72ad52f6000
    0xbfc0d77e7cd09000
    0xbfc0d77e7cd09000
    0xbfbfec9131dbe000
    0xbfbe27076e2b0000
    0xbfbe27076e2b0000
    0xbfbc5e548f5bc000
    0xbfba926d3a4ae000
    0xbfba926d3a4ae000
    0xbfb8c345d631a000
    0xbfb8c345d631a000
    0xbfb6f0d28ae56000
    0xbfb51b073f062000
    0xbfb51b073f062000
    0xbfb341d7961be000
    0xbfb341d7961be000
    0xbfb16536eea38000
    0xbfaf0a30c0118000
    0xbfaf0a30c0118000
    0xbfab42dd71198000
    0xbfab42dd71198000
    0xbfa77458f632c000
    0xbfa77458f632c000
    0xbfa39e87b9fec000
    0xbfa39e87b9fec000
    0xbf9f829b0e780000
    0xbf9f829b0e780000
    0xbf97b91b07d58000
    0xbf8fc0a8b0fc0000
    0xbf8fc0a8b0fc0000
    0xbf7fe02a6b100000
    0xbf7fe02a6b100000
    0x0000000000000000
    0x0000000000000000
    0x3f80101575890000
    0x3f90205658938000
    0x3f98492528c90000
    0x3fa0415d89e74000
    0x3fa466aed42e0000
    0x3fa894aa149fc000
    0x3faccb73cdddc000
    0x3faeea31c006c000
    0x3fb1973bd1466000
    0x3fb3bdf5a7d1e000
    0x3fb5e95a4d97a000
    0x3fb700d30aeac000
    0x3fb9335e5d594000
    0x3fbb6ac88dad6000
    0x3fbc885801bc4000
    0x3fbec739830a2000
    0x3fbfe89139dbe000
    0x3fc1178e8227e000
    0x3fc1aa2b7e23f000
    0x3fc2d1610c868000
    0x3fc365fcb0159000
    0x3fc4913d8333b000
    0x3fc527e5e4a1b000
    0x3fc6574ebe8c1000
    0x3fc6f0128b757000
    0x3fc7898d85445000
    0x3fc8beafeb390000
    0x3fc95a5adcf70000
    0x3fca93ed3c8ae000
    0x3fcb31d8575bd000
    0x3fcbd087383be000
    0x3fcc6ffbc6f01000
    0x3fcdb13db0d49000
    0x3fce530effe71000
    0x3fcef5ade4dd0000
    0x3fcf991c6cb3b000
    0x3fd07138604d5800
    0x3fd0c42d67616000
    0x3fd1178e8227e800
    0x3fd16b5ccbacf800
    0x3fd1bf99635a6800
    0x3fd214456d0eb800
    0x3fd2bef07cdc9000
    0x3fd314f1e1d36000
    0x3fd36b6776be1000
    0x3fd3c25277333000
    0x3fd419b423d5e800
    0x3fd4718dc271c800
    0x3fd4c9e09e173000
    0x3fd522ae0738a000
    0x3fd57bf753c8d000
    0x3fd5d5bddf596000))
(define math-pow-f64-logctail-bits : (Array u64 128)
  (math-bits-array
    0x3cfab42428375680
    0xbd1ca508d8e0f720
    0xbd2362a4d5b6506d
    0xbce684e49eb067d5
    0xbd041b6993293ee0
    0x3d13d82f484c84cc
    0x3cdc42f3ed820b3a
    0x3d20b1c686519460
    0x3d25594dd4c58092
    0x3d267b1e99b72bd8
    0x3d15ca14b6cfb03f
    0x3d15ca14b6cfb03f
    0xbd165a242853da76
    0xbd1fafbc68e75404
    0x3d1f1fc63382a8f0
    0xbd26a8c4fd055a66
    0xbd0c6bee7ef4030e
    0xbcf036b89ef42d7f
    0xbcf036b89ef42d7f
    0x3d0d572aab993c87
    0x3d2b26b79c86af24
    0xbd172f4f543fff10
    0x3d21ba91bbca681b
    0x3d27794f689f8434
    0x3d27794f689f8434
    0x3d194eb0318bb78f
    0x3cba4e633fcd9066
    0xbd258c64dc46c1ea
    0xbd258c64dc46c1ea
    0xbd2ad1d904c1d4e3
    0x3d2bbdbf7fdbfa09
    0x3d2bdb9072534a58
    0x3d2bdb9072534a58
    0xbd10e46aa3b2e266
    0xbd1e9e439f105039
    0xbd1e9e439f105039
    0xbd20de8b90075b8f
    0x3d170cc16135783c
    0x3d170cc16135783c
    0x3cf178864d27543a
    0xbd248d301771c408
    0xbd2e80a41811a396
    0xbd2e80a41811a396
    0x3d0a699688e85bf4
    0x3d0a699688e85bf4
    0xbd2575545ca333f2
    0x3d2a342c2af0003c
    0x3d2a342c2af0003c
    0xbd1d0c57585fbe06
    0x3d253935e85baac8
    0x3d253935e85baac8
    0x3d137c294d2f5668
    0x3d137c294d2f5668
    0xbd269737c93373da
    0x3d1f025b61c65e57
    0x3d1f025b61c65e57
    0x3d2c5edaccf913df
    0x3d2c5edaccf913df
    0x3d147c5e768fa309
    0x3d2d599e83368e91
    0x3d2d599e83368e91
    0x3d1c827ae5d6704c
    0x3d1c827ae5d6704c
    0xbd2cfc4634f2a1ee
    0xbd2cfc4634f2a1ee
    0x3cf502b7f526feaa
    0x3cf502b7f526feaa
    0xbd2980267c7e09e4
    0xbd2980267c7e09e4
    0xbd288d5493faa639
    0xbcdf1e7cf6d3a69c
    0xbcdf1e7cf6d3a69c
    0xbd19e23f0dda40e4
    0xbd19e23f0dda40e4
    0x0000000000000000
    0x0000000000000000
    0xbd10c76b999d2be8
    0xbd23dc5b06e2f7d2
    0xbd2aa0ba325a0c34
    0x3d0111c05cf1d753
    0xbd2c167375bdfd28
    0xbd197995d05a267d
    0xbd1a68f247d82807
    0xbd0e113e4fc93b7b
    0xbd25325d560d9e9b
    0x3d2cc85ea5db4ed7
    0xbd2c69063c5d1d1e
    0x3cec1e8da99ded32
    0x3d23115c3abd47da
    0xbd1390802bf768e5
    0x3d2646d1c65aacd3
    0xbd2dc068afe645e0
    0xbd2534d64fa10afd
    0x3d21ef78ce2d07f2
    0x3d2ca78e44389934
    0x3d039d6ccb81b4a1
    0x3cc62fa8234b7289
    0x3d25837954fdb678
    0x3d2633e8e5697dc7
    0x3d19cf8b2c3c2e78
    0xbd25118de59c21e1
    0xbd1c661070914305
    0xbd073d54aae92cd1
    0x3d07f22858a0ff6f
    0xbd28724350562169
    0xbd0c358d4eace1aa
    0xbd2d4bc4595412b6
    0xbcf1ec72c5962bd2
    0xbd2aff2af715b035
    0x3cc212276041f430
    0xbcca211565bb8e11
    0x3d1bcbecca0cdf30
    0x3cf89cdb16ed4e91
    0x3d27188b163ceae9
    0xbd2c210e63a5f01c
    0x3d2b9acdf7a51681
    0x3d2ca6ed5147bdb7
    0x3d0a87deba46baea
    0x3d2a9cfa4a5004f4
    0xbd28e27ad3213cb8
    0x3d116ecdb0f177c8
    0x3d183b54b606bd5c
    0x3d08e436ec90e09d
    0xbd2f27ce0967d675
    0xbd2e20891b0ad8a4
    0x3d2ebe708164c759
    0x3d1fadedee5d40ef
    0xbd0a0b2a08a465dc))

;: Internal binary64 pow logarithm result: rounded value plus a tail holding
;: about fifteen extra bits of precision, mirroring `log_inline`'s out-param.
(defstruct MathPowLogF64Result
  (y f64)
  (tail f64))

;: Evaluate log(x) for the binary64 pow reduction; `ix` is the bit pattern of
;: a positive finite x, pre-normalized with the sign bit as exponent for
;: subnormals. Mirrors musl pow.c `log_inline` on the non-FMA path: OFF is
;: 0x3fe6955500000000, the table is 128-way, and the degree-eight polynomial
;: uses the scaled coefficients from pow_data.c.
(define (math-pow-f64-log [ix : u64]) : MathPowLogF64Result
  (let
    [tmp : u64 (- ix (cast 0x3fe6955500000000 : u64))]
    [index : i64 (cast (bit-and (shr tmp 45) (cast 127 : u64)) : i64)]
    [k : i64 (shr (cast tmp : i64) 52)]
    [iz : u64 (- ix (bit-and tmp (cast 0xfff0000000000000 : u64)))]
    [z : f64 (stdlib.math.f64-from-bits iz)]
    [kd : f64 (cast k : f64)]
    [invc : f64
      (stdlib.math.f64-from-bits (array-ref math-pow-f64-invc-bits index))]
    [logc : f64
      (stdlib.math.f64-from-bits (array-ref math-pow-f64-logc-bits index))]
    [logctail : f64
      (stdlib.math.f64-from-bits (array-ref math-pow-f64-logctail-bits index))]
    [zhi : f64
      (stdlib.math.f64-from-bits
        (bit-and (+ iz (cast 0x80000000 : u64)) (cast 0xffffffff00000000 : u64)))]
    [zlo : f64 (- z zhi)]
    [rhi : f64 (- (* zhi invc) 1.0)]
    [rlo : f64 (* zlo invc)]
    [r : f64 (+ rhi rlo)]
    [t1 : f64 (+ (* kd 0.69314718055989033) logc)]
    [t2 : f64 (+ t1 r)]
    [lo1 : f64 (+ (* kd 5.4979230187083712e-14) logctail)]
    [lo2 : f64 (+ (- t1 t2) r)]
    [ar : f64 (* -0.5 r)]
    [ar2 : f64 (* r ar)]
    [ar3 : f64 (* r ar2)]
    [arhi : f64 (* -0.5 rhi)]
    [arhi2 : f64 (* rhi arhi)]
    [hi : f64 (+ t2 arhi2)]
    [lo3 : f64 (* rlo (+ ar arhi))]
    [lo4 : f64 (+ (- t2 hi) arhi2)]
    [p : f64
      (*
        ar3
        (+
          (+ -0.66666666666666785 (* r 0.50000000000000067))
          (*
            ar2
            (+
              (+ 0.79999999953239764 (* r -0.66666666634877392))
              (* ar2 (+ -1.1429096284595011 (* r 1.0000415263675542)))))))]
    [lo : f64 (+ (+ (+ (+ lo1 lo2) lo3) lo4) p)]
    [y : f64 (+ hi lo)]
    (MathPowLogF64Result y (+ (- hi y) lo))))

;: Complete a binary64 pow result whose table scale may overflow or
;: underflow. Mirrors musl pow.c `specialcase`, including the sign-of-zero
;: fix the exp port does not need (pow results can be negative through the
;: sign bias). The rounding-mode-only DBL_MAX corner case is dropped because
;: TypeLisp has no directed-rounding modes.
(define (math-pow-f64-exp-special [tmp : f64] [scale-bits : u64] [k-bits : u64]) : f64
  (if (= (bit-and k-bits (cast 0x80000000 : u64)) (cast 0 : u64))
    (let
      [adjusted-bits : u64 (- scale-bits (shl (cast 1009 : u64) 52))]
      [scale : f64 (stdlib.math.f64-from-bits adjusted-bits)]
      [y : f64 (+ scale (* scale tmp))]
      (* y 5.4861240687936887e+303))
    (let
      [adjusted-bits : u64 (+ scale-bits (shl (cast 1022 : u64) 52))]
      [scale : f64 (stdlib.math.f64-from-bits adjusted-bits)]
      [y : f64 (+ scale (* scale tmp))]
      (if (and (< y 1.0) (> y -1.0))
        (let
          [one : f64
            (if (< y 0.0)
              -1.0
              1.0)]
          [lo : f64 (+ (- scale y) (* scale tmp))]
          [hi : f64 (+ one y)]
          (set! lo (+ (+ (- one hi) y) lo))
          (set! y (- (+ hi lo) one))
          (if (= y 0.0)
            (set!
              y
              (stdlib.math.f64-from-bits
                (bit-and adjusted-bits (cast 0x8000000000000000 : u64))))
            unit))
        unit)
      (* 2.2250738585072014e-308 y))))

;: Evaluate the binary64 pow exponential reduction once the argument is known
;: to be finite and in the table range; `special` marks the upstream
;: `abstop == 0` path that must route through `math-pow-f64-exp-special`.
(define (math-pow-f64-exp-core
  [x : f64]
  [xtail : f64]
  [sign-bias : u64]
  [special : bool]) : f64
  (let
    [z : f64 (* 184.66496523378731 x)]
    [rounded : f64 (+ z 6755399441055744.0)]
    [k-bits : u64 (stdlib.math.f64-to-bits rounded)]
    [k : f64 (- rounded 6755399441055744.0)]
    [r : f64
      (+
        (+ (+ x (* k -0.0054152123481117087)) (* k -1.2864023111638346e-14))
        xtail)]
    [index : i64 (cast (bit-and k-bits (cast 127 : u64)) : i64)]
    [top : u64 (shl (+ k-bits sign-bias) 45)]
    [tail : f64
      (stdlib.math.f64-from-bits (array-ref math-exp-f64-tail-bits index))]
    [sbits : u64 (+ (array-ref math-exp-f64-scale-bits index) top)]
    [r2 : f64 (* r r)]
    [tmp : f64
      (+
        (+ (+ tail r) (* r2 (+ 0.49999999999996786 (* r 0.16666666666665886))))
        (* (* r2 r2) (+ 0.041666680841067401 (* r 0.0083333358530595491))))]
    (if special
      (math-pow-f64-exp-special tmp sbits k-bits)
      (let
        [scale : f64 (stdlib.math.f64-from-bits sbits)]
        (+ scale (* scale tmp))))))

;: Compute sign*exp(x+xtail) for the binary64 pow reduction, where the sign
;: bias is 0 or 0x40000 (musl SIGN_BIAS, 0x800 << EXP_TABLE_BITS). Mirrors
;: musl pow.c `exp_inline`, reusing the shared `__exp_data` field arrays.
(define (math-pow-f64-exp [x : f64] [xtail : f64] [sign-bias : u64]) : f64
  (let
    [abstop : u64
      (bit-and (shr (stdlib.math.f64-to-bits x) 52) (cast 0x7ff : u64))]
    [extreme : bool (>= (- abstop (cast 0x3c9 : u64)) (cast 0x3f : u64))]
    (cond
      [(and extreme (>= (- abstop (cast 0x3c9 : u64)) (cast 0x80000000 : u64)))
        (let
          [one : f64 (+ 1.0 x)]
          (if (!= sign-bias (cast 0 : u64))
            (- 0.0 one)
            one))]
      [(and extreme (>= abstop (cast 0x409 : u64)))
        (if (!= (shr (stdlib.math.f64-to-bits x) 63) (cast 0 : u64))
          (if (!= sign-bias (cast 0 : u64))
            -0.0
            0.0)
          (if (!= sign-bias (cast 0 : u64))
            (stdlib.math.f64-negative-infinity)
            (stdlib.math.f64-positive-infinity)))]
      [else (math-pow-f64-exp-core x xtail sign-bias extreme)])))

;: Return 0 when the nonzero finite binary64 bit pattern is not integral, 1
;: for an odd integer, and 2 for an even integer. Mirrors musl `checkint`.
(define (math-pow-f64-checkint [iy : u64]) : i64
  (let
    [e : u64 (bit-and (shr iy 52) (cast 0x7ff : u64))]
    [shift : i64 (- 1075 (cast e : i64))]
    (cond
      [(< e (cast 0x3ff : u64)) 0]
      [(> e (cast 0x433 : u64)) 2]
      [(!=
          (bit-and iy (- (shl (cast 1 : u64) shift) (cast 1 : u64)))
          (cast 0 : u64))
        0]
      [(!= (bit-and iy (shl (cast 1 : u64) shift)) (cast 0 : u64)) 1]
      [else 2])))

;: True when the bit pattern is zero, infinity, or NaN. Mirrors musl
;: `zeroinfnan`.
(define (math-pow-f64-zero-inf-nan? [bits : u64]) : bool
  (>=
    (- (* (cast 2 : u64) bits) (cast 1 : u64))
    (cast 0xffdfffffffffffff : u64)))

;: Evaluate the finite binary64 pow path after the decision table: compute
;: log(x) with its tail, multiply by y in split precision, and exponentiate.
(define (math-pow-f64-main [ix : u64] [y : f64] [iy : u64] [sign-bias : u64]) : f64
  (let
    [log-result : MathPowLogF64Result (math-pow-f64-log ix)]
    [hi : f64 log-result.y]
    [lo : f64 log-result.tail]
    [yhi : f64
      (stdlib.math.f64-from-bits (bit-and iy (cast 0xfffffffff8000000 : u64)))]
    [ylo : f64 (- y yhi)]
    [lhi : f64
      (stdlib.math.f64-from-bits
        (bit-and (stdlib.math.f64-to-bits hi) (cast 0xfffffffff8000000 : u64)))]
    [llo : f64 (+ (- hi lhi) lo)]
    [ehi : f64 (* yhi lhi)]
    [elo : f64 (+ (* ylo lhi) (* y llo))]
    (math-pow-f64-exp ehi elo sign-bias)))

;: Return binary64 `x` raised to `y` without allocation or platform math
;: calls.
;:
;: The implementation ports musl `pow` (the Arm optimized-routines
;: algorithm): a 128-way logarithm table with a degree-eight polynomial, a
;: split-precision multiply by the exponent, and the shared exponential
;: table. Worst-case error is about 0.54 ULP in default round-to-nearest
;: mode, within the one-ULP contract. The full IEEE decision table is
;: implemented: any base to a zero exponent is one, one to any exponent is
;: one, negative one to an infinity exponent is one, NaN in either operand
;: propagates, infinities and signed zeros follow the usual sign rules
;: (negative zero or infinity to an odd integral exponent stays negative),
;: a negative finite base with a nonintegral exponent yields NaN, overflow
;: returns the signed infinity, and underflow is gradual through subnormals.
;: Floating exception flags and signaling-NaN payload behavior are outside
;: the contract.
(define (f64-pow [x : f64] [y : f64]) : f64
  (let
    [ix : u64 (stdlib.math.f64-to-bits x)]
    [iy : u64 (stdlib.math.f64-to-bits y)]
    [topx : u64 (shr ix 52)]
    [topy : u64 (shr iy 52)]
    [sign-bias : u64 (cast 0 : u64)]
    [domain-error : bool false]
    (if (or
      (>= (- topx (cast 1 : u64)) (cast 0x7fe : u64))
      (>=
        (- (bit-and topy (cast 0x7ff : u64)) (cast 0x3be : u64))
        (cast 0x80 : u64)))
      (cond
        [(math-pow-f64-zero-inf-nan? iy)
          (cond
            [(= (* (cast 2 : u64) iy) (cast 0 : u64)) 1.0]
            [(= ix (cast 0x3ff0000000000000 : u64)) 1.0]
            [(or
                (> (* (cast 2 : u64) ix) (cast 0xffe0000000000000 : u64))
                (> (* (cast 2 : u64) iy) (cast 0xffe0000000000000 : u64)))
              (+ x y)]
            [(= (* (cast 2 : u64) ix) (cast 0x7fe0000000000000 : u64)) 1.0]
            [(=
                (< (* (cast 2 : u64) ix) (cast 0x7fe0000000000000 : u64))
                (= (shr iy 63) (cast 0 : u64)))
              0.0]
            [else (* y y)])]
        [(math-pow-f64-zero-inf-nan? ix)
          (let
            [x2 : f64 (* x x)]
            (if (and
              (!= (shr ix 63) (cast 0 : u64))
              (= (math-pow-f64-checkint iy) 1))
              (set! x2 (* x2 -1.0))
              unit)
            (if (!= (shr iy 63) (cast 0 : u64))
              (/ 1.0 x2)
              x2))]
        [else
          (if (!= (shr ix 63) (cast 0 : u64))
            (let
              [yint : i64 (math-pow-f64-checkint iy)]
              (if (= yint 0)
                (set! domain-error true)
                (begin
                  (if (= yint 1)
                    (set! sign-bias (cast 0x40000 : u64))
                    unit)
                  (set! ix (bit-and ix (cast 0x7fffffffffffffff : u64)))
                  (set! topx (bit-and topx (cast 0x7ff : u64))))))
            unit)
          (if domain-error
            (stdlib.math.f64-quiet-nan)
            (if (>=
              (- (bit-and topy (cast 0x7ff : u64)) (cast 0x3be : u64))
              (cast 0x80 : u64))
              (cond
                [(= ix (cast 0x3ff0000000000000 : u64)) 1.0]
                [(< (bit-and topy (cast 0x7ff : u64)) (cast 0x3be : u64))
                  (if (> ix (cast 0x3ff0000000000000 : u64))
                    (+ 1.0 y)
                    (- 1.0 y))]
                [else
                  (if (=
                    (> ix (cast 0x3ff0000000000000 : u64))
                    (< topy (cast 0x800 : u64)))
                    (stdlib.math.f64-positive-infinity)
                    0.0)])
              (begin
                (when
                  (= topx (cast 0 : u64))
                  (set!
                    ix
                    (bit-and
                      (stdlib.math.f64-to-bits (* x 4503599627370496.0))
                      (cast 0x7fffffffffffffff : u64)))
                  (set! ix (- ix (shl (cast 52 : u64) 52))))
                (math-pow-f64-main ix y iy sign-bias))))])
      (math-pow-f64-main ix y iy sign-bias))))

;: Exact binary32 pow log2 interval payloads, evaluated as binary64.
(define math-pow-f32-invc-bits : (Array u64 16)
  (math-bits-array
    0x3ff661ec79f8f3be
    0x3ff571ed4aaf883d
    0x3ff49539f0f010b0
    0x3ff3c995b0b80385
    0x3ff30d190c8864a5
    0x3ff25e227b0b8ea0
    0x3ff1bb4a4a1a343f
    0x3ff12358f08ae5ba
    0x3ff0953f419900a7
    0x3ff0000000000000
    0x3fee608cfd9a47ac
    0x3feca4b31f026aa0
    0x3feb2036576afce6
    0x3fe9c2d163a1aa2d
    0x3fe886e6037841ed
    0x3fe767dcf5534862))
(define math-pow-f32-logc-bits : (Array u64 16)
  (math-bits-array
    0xbfdefec65b963019
    0xbfdb0b6832d4fca4
    0xbfd7418b0a1fb77b
    0xbfd39de91a6dcf7b
    0xbfd01d9bf3f2b631
    0xbfc97c1d1b3b7af0
    0xbfc2f9e393af3c9f
    0xbfb960cbbf788d5c
    0xbfaa6f9db6475fce
    0x0000000000000000
    0x3fb338ca9f24f53d
    0x3fc476a9543891ba
    0x3fce840b4ac4e4d2
    0x3fd40645f0c6651c
    0x3fd88e9c2c1b9ff8
    0x3fdce0a44eb17bcc))

;: Evaluate log2(x) in binary64 for the binary32 pow reduction; `ix` is the
;: bit pattern of a positive finite binary32 x, pre-normalized with the sign
;: bit as exponent for subnormals. Mirrors musl powf.c `log2_inline` with
;: POWF_SCALE 1 (TOINT intrinsics off), so the upstream scale multipliers are
;: the identity.
(define (math-powf-log2 [ix : u32]) : f64
  (let
    [tmp : u32 (- ix (cast 0x3f330000 : u32))]
    [index : i64 (cast (bit-and (shr tmp 19) (cast 15 : u32)) : i64)]
    [top : u32 (bit-and tmp (cast 0xff800000 : u32))]
    [iz : u32 (- ix top)]
    [k : i64 (cast (shr (cast top : i32) 23) : i64)]
    [invc : f64
      (stdlib.math.f64-from-bits (array-ref math-pow-f32-invc-bits index))]
    [logc : f64
      (stdlib.math.f64-from-bits (array-ref math-pow-f32-logc-bits index))]
    [z : f64 (cast (stdlib.math.f32-from-bits iz) : f64)]
    [r : f64 (- (* z invc) 1.0)]
    [y0 : f64 (+ logc (cast k : f64))]
    [r2 : f64 (* r r)]
    [y : f64 (+ (* 0.28845758110921399 r) -0.36092606229713164)]
    [p : f64 (+ (* 0.48089848147257702 r) -0.72134746750062906)]
    [r4 : f64 (* r2 r2)]
    [q : f64 (+ (* 1.4426950408774342 r) y0)]
    (set! q (+ (* p r2) q))
    (set! y (+ (* y r4) q))
    y))

;: Compute 2^(y*log2(x)) for the binary32 pow reduction. Mirrors musl powf.c
;: `exp2_inline` on the non-TOINT path: the shift constant is
;: __exp2f_data.shift_scaled (0x1.8p+47) and the polynomial is the unscaled
;: __exp2f_data.poly. The 32-entry `__exp2f_data.tab` is every fourth
;: `__exp_data` scale row (verified against exp2f_data.c, the same reuse the
;: f32-exp port relies on), so both read the same scale-word array.
(define (math-powf-exp2 [xd : f64] [sign-bias : u32]) : f32
  (let
    [rounded : f64 (+ xd 211106232532992.0)]
    [ki : u64 (stdlib.math.f64-to-bits rounded)]
    [kd : f64 (- rounded 211106232532992.0)]
    [r : f64 (- xd kd)]
    [index : i64 (* (cast (bit-and ki (cast 31 : u64)) : i64) 4)]
    [ski : u64 (+ ki (cast sign-bias : u64))]
    [t : u64 (+ (array-ref math-exp-f64-scale-bits index) (shl ski 47))]
    [s : f64 (stdlib.math.f64-from-bits t)]
    [z : f64 (+ (* 0.055503615593415351 r) 0.2402284522445722)]
    [r2 : f64 (* r r)]
    [y : f64 (+ (* 0.69314718069162029 r) 1.0)]
    (set! y (+ (* z r2) y))
    (set! y (* y s))
    (cast y : f32)))

;: Return 0 when the nonzero finite binary32 bit pattern is not integral, 1
;: for an odd integer, and 2 for an even integer. Mirrors musl `checkint`.
(define (math-powf-checkint [iy : u32]) : i64
  (let
    [e : u32 (bit-and (shr iy 23) (cast 0xff : u32))]
    [shift : i64 (- 150 (cast e : i64))]
    (cond
      [(< e (cast 0x7f : u32)) 0]
      [(> e (cast 0x96 : u32)) 2]
      [(!=
          (bit-and iy (- (shl (cast 1 : u32) shift) (cast 1 : u32)))
          (cast 0 : u32))
        0]
      [(!= (bit-and iy (shl (cast 1 : u32) shift)) (cast 0 : u32)) 1]
      [else 2])))

;: True when the binary32 bit pattern is zero, infinity, or NaN. Mirrors
;: musl `zeroinfnan`.
(define (math-powf-zero-inf-nan? [bits : u32]) : bool
  (>= (- (* (cast 2 : u32) bits) (cast 1 : u32)) (cast 0xfeffffff : u32)))

;: Evaluate the finite binary32 pow path after the decision table: form
;: y*log2(x) in binary64, map the overflow and underflow boundaries, and
;: exponentiate. The upstream WANT_ROUNDING boundary checks collapse to
;: their round-to-nearest results.
(define (math-powf-main [ix : u32] [y : f32] [sign-bias : u32]) : f32
  (let
    [ylogx : f64 (* (cast y : f64) (math-powf-log2 ix))]
    [ylogx-bits : u64 (stdlib.math.f64-to-bits ylogx)]
    (if (>=
      (bit-and (shr ylogx-bits 47) (cast 0xffff : u64))
      (cast 0x80bf : u64))
      (cond
        [(<= ylogx -150.0)
          (if (!= sign-bias (cast 0 : u32))
            (cast -0.0 : f32)
            (cast 0.0 : f32))]
        [(> ylogx 127.99999991400867)
          (if (> ylogx 127.99999995700433)
            (if (!= sign-bias (cast 0 : u32))
              (stdlib.math.f32-negative-infinity)
              (stdlib.math.f32-positive-infinity))
            (if (!= sign-bias (cast 0 : u32))
              (cast -3.4028234663852886e+38 : f32)
              (cast 3.4028234663852886e+38 : f32)))]
        [else (math-powf-exp2 ylogx sign-bias)])
      (math-powf-exp2 ylogx sign-bias))))

;: Return binary32 `x` raised to `y` without allocation or platform math
;: calls.
;:
;: The implementation ports musl `powf`: a 16-way log2 table with a
;: degree-five polynomial evaluated in binary64, followed by a 32-way exp2
;: reduction. Worst-case error is about 0.82 ULP in default round-to-nearest
;: mode, within the one-ULP contract. Special-value behavior matches
;: `f64-pow`; floating exception flags and signaling-NaN payload behavior
;: are outside the contract.
(define (f32-pow [x : f32] [y : f32]) : f32
  (let
    [ix : u32 (stdlib.math.f32-to-bits x)]
    [iy : u32 (stdlib.math.f32-to-bits y)]
    [sign-bias : u32 (cast 0 : u32)]
    [domain-error : bool false]
    (if (or
      (>= (- ix (cast 0x00800000 : u32)) (cast 0x7f000000 : u32))
      (math-powf-zero-inf-nan? iy))
      (cond
        [(math-powf-zero-inf-nan? iy)
          (cond
            [(= (* (cast 2 : u32) iy) (cast 0 : u32)) (cast 1.0 : f32)]
            [(= ix (cast 0x3f800000 : u32)) (cast 1.0 : f32)]
            [(or
                (> (* (cast 2 : u32) ix) (cast 0xff000000 : u32))
                (> (* (cast 2 : u32) iy) (cast 0xff000000 : u32)))
              (+ x y)]
            [(= (* (cast 2 : u32) ix) (cast 0x7f000000 : u32)) (cast 1.0 : f32)]
            [(=
                (< (* (cast 2 : u32) ix) (cast 0x7f000000 : u32))
                (= (bit-and iy (cast 0x80000000 : u32)) (cast 0 : u32)))
              (cast 0.0 : f32)]
            [else (* y y)])]
        [(math-powf-zero-inf-nan? ix)
          (let
            [x2 : f32 (* x x)]
            (if (and
              (!= (bit-and ix (cast 0x80000000 : u32)) (cast 0 : u32))
              (= (math-powf-checkint iy) 1))
              (set! x2 (* x2 (cast -1.0 : f32)))
              unit)
            (if (!= (bit-and iy (cast 0x80000000 : u32)) (cast 0 : u32))
              (/ (cast 1.0 : f32) x2)
              x2))]
        [else
          (if (!= (bit-and ix (cast 0x80000000 : u32)) (cast 0 : u32))
            (let
              [yint : i64 (math-powf-checkint iy)]
              (if (= yint 0)
                (set! domain-error true)
                (begin
                  (if (= yint 1)
                    (set! sign-bias (cast 0x10000 : u32))
                    unit)
                  (set! ix (bit-and ix (cast 0x7fffffff : u32))))))
            unit)
          (if domain-error
            (stdlib.math.f32-quiet-nan)
            (begin
              (when
                (< ix (cast 0x00800000 : u32))
                (set!
                  ix
                  (bit-and
                    (stdlib.math.f32-to-bits (* x (cast 8388608.0 : f32)))
                    (cast 0x7fffffff : u32)))
                (set! ix (- ix (shl (cast 23 : u32) 23))))
              (math-powf-main ix y sign-bias)))])
      (math-powf-main ix y sign-bias))))

;: Return `base` raised to `exponent` for `f64` or `f32` expressions,
;: preserving the shared operand type and evaluating each expression once.
(defmacro (pow [base : comptime.Expr] [exponent : comptime.Expr]) : comptime.Expr
  (match (type-kind (comptime.expr-type base))
    ["f64"
      (match (type-kind (comptime.expr-type exponent))
        ["f64" `(stdlib.math.f64-pow ,base ,exponent)]
        [_
          (comptime.comptime-error
            (comptime.string-append
              "math.pow: exponent type must match base type f64, found "
              (type-kind (comptime.expr-type exponent))))])]
    ["f32"
      (match (type-kind (comptime.expr-type exponent))
        ["f32" `(stdlib.math.f32-pow ,base ,exponent)]
        [_
          (comptime.comptime-error
            (comptime.string-append
              "math.pow: exponent type must match base type f32, found "
              (type-kind (comptime.expr-type exponent))))])]
    [_
      (comptime.comptime-error
        (comptime.string-append
          "math.pow: expected f64 or f32, found "
          (type-kind (comptime.expr-type base))))]))

;; The trigonometric implementation below is derived from the musl/fdlibm
;; sources pinned in MATH_LICENSES.md. Keep the constants as exact IEEE-754
;; bit patterns and preserve the written operation order: the polynomial error
;; bounds and compensated argument reduction depend on both.
;: Internal quadrant and compensated remainder from pi/2 argument reduction.
(defstruct MathTrigReduction
  (quadrant i64)
  (hi f64)
  (lo f64))

;; The complete 66-limb fdlibm 2/pi table and eight non-overlapping pi/2
;; pieces stay exact. Finite binary64 exponents bound jv by 41; the reducer
;; guards its negative prefix and uses a 20-slot local convolution window.
(define math-trig-two-over-pi-limbs : (Array u64 66)
  (math-bits-array
    0x0000000000a2f983
    0x00000000006e4e44
    0x00000000001529fc
    0x00000000002757d1
    0x0000000000f534dd
    0x0000000000c0db62
    0x000000000095993c
    0x0000000000439041
    0x0000000000fe5163
    0x0000000000abdebb
    0x0000000000c561b7
    0x0000000000246e3a
    0x0000000000424dd2
    0x0000000000e00649
    0x00000000002eea09
    0x0000000000d1921c
    0x0000000000fe1deb
    0x00000000001cb129
    0x0000000000a73ee8
    0x00000000008235f5
    0x00000000002ebb44
    0x000000000084e99c
    0x00000000007026b4
    0x00000000005f7e41
    0x00000000003991d6
    0x0000000000398353
    0x000000000039f49c
    0x0000000000845f8b
    0x0000000000bdf928
    0x00000000003b1ff8
    0x000000000097ffde
    0x000000000005980f
    0x0000000000ef2f11
    0x00000000008b5a0a
    0x00000000006d1f6d
    0x0000000000367ecf
    0x000000000027cb09
    0x0000000000b74f46
    0x00000000003f669e
    0x00000000005fea2d
    0x00000000007527ba
    0x0000000000c7ebe5
    0x0000000000f17b3d
    0x00000000000739f7
    0x00000000008a5292
    0x0000000000ea6bfb
    0x00000000005fb11f
    0x00000000008d5d08
    0x0000000000560330
    0x000000000046fc7b
    0x00000000006babf0
    0x0000000000cfbc20
    0x00000000009af436
    0x00000000001da9e3
    0x000000000091615e
    0x0000000000e61b08
    0x0000000000659985
    0x00000000005f14a0
    0x000000000068408d
    0x0000000000ffd880
    0x00000000004d7327
    0x0000000000310606
    0x00000000001556ca
    0x000000000073a8c9
    0x000000000060e27b
    0x0000000000c08c6b))
(define math-trig-pi-over-two-piece-bits : (Array u64 8)
  (math-bits-array
    0x3ff921fb40000000
    0x3e74442d00000000
    0x3cf8469880000000
    0x3b78cc5160000000
    0x39f01b8380000000
    0x387a252040000000
    0x36e3822280000000
    0x3569f31d00000000))

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
    [iq : (Array i64 20) (make-array i64 20)]
    [f : (Array f64 20) (make-array f64 20)]
    [fq : (Array f64 20) (make-array f64 20)]
    [q : (Array f64 20) (make-array f64 20)]
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
    (if (< jv 0)
      (set! jv 0)
      unit)
    (set! q0 (- e0 (* 24 (+ jv 1))))
    ;; f[0..jx+jk] selects the exponent-local window of the 2/pi table.
    (set! j (- jv jx))
    (set! m (+ jx jk))
    (set! i 0)
    (while (<= i m)
      (set!
        (array-ref f i)
        (if (< j 0)
          0.0
          (cast (array-ref math-trig-two-over-pi-limbs j) : f64)))
      (set! i (+ i 1))
      (set! j (+ j 1)))
    ;; q is the local convolution of the significand and 2/pi limbs.
    (set! i 0)
    (while (<= i jk)
      (set! fw 0.0)
      (set! j 0)
      (while (<= j jx)
        (set!
          fw
          (+
            fw
            (* (math-trig-input-limb j x0 x1 x2) (array-ref f (- (+ jx i) j)))))
        (set! j (+ j 1)))
      (set! (array-ref q i) fw)
      (set! i (+ i 1)))
    (set! jz jk)
    (while need-recompute
      ;; Distill q into base-2^24 integer limbs in reverse order.
      (set! i 0)
      (set! j jz)
      (set! z (array-ref q jz))
      (while (> j 0)
        (set! fw (cast (cast (* 0.000000059604644775390625 z) : i64) : f64))
        (set! (array-ref iq i) (cast (- z (* 16777216.0 fw)) : i64))
        (set! z (+ (array-ref q (- j 1)) fw))
        (set! i (+ i 1))
        (set! j (- j 1)))
      ;; Extract N mod 8 and the fractional product.
      (set! z (stdlib.math.f64-scalbn z q0))
      (set! z (- z (* 8.0 (cast (cast (* z 0.125) : i64) : f64))))
      (set! n (cast z : i64))
      (set! z (- z (cast n : f64)))
      (set! ih 0)
      (cond
        [(> q0 0)
          (set! i (shr (array-ref iq (- jz 1)) (- 24 q0)))
          (set! n (+ n i))
          (set!
            (array-ref iq (- jz 1))
            (- (array-ref iq (- jz 1)) (shl i (- 24 q0))))
          (set! ih (shr (array-ref iq (- jz 1)) (- 23 q0)))]
        [(= q0 0) (set! ih (shr (array-ref iq (- jz 1)) 23))]
        [(>= z 0.5) (set! ih 2)]
        [else unit])
      ;; Fold q > 1/2 to 1-q and remember the remainder sign.
      (when
        (> ih 0)
        (set! n (+ n 1))
        (set! carry 0)
        (set! i 0)
        (while (< i jz)
          (set! j (array-ref iq i))
          (if (= carry 0)
            (when
              (!= j 0)
              (set! carry 1)
              (set! (array-ref iq i) (- 0x1000000 j)))
            (set! (array-ref iq i) (- 0xffffff j)))
          (set! i (+ i 1)))
        (if (= q0 1)
          (set!
            (array-ref iq (- jz 1))
            (bit-and (array-ref iq (- jz 1)) 0x7fffff))
          (if (= q0 2)
            (set!
              (array-ref iq (- jz 1))
              (bit-and (array-ref iq (- jz 1)) 0x3fffff))
            unit))
        (when
          (= ih 2)
          (set! z (- 1.0 z))
          (if (!= carry 0)
            (set! z (- z (stdlib.math.f64-scalbn 1.0 q0)))
            unit)))
      ;; Exact cancellation can consume the current table window. Extend
      ;; the convolution just far enough and distill it again.
      (set! need-recompute false)
      (when
        (= z 0.0)
        (set! j 0)
        (set! i (- jz 1))
        (while (>= i jk)
          (set! j (bit-or j (array-ref iq i)))
          (set! i (- i 1)))
        (when
          (= j 0)
          (set! k 1)
          (while (= (array-ref iq (- jk k)) 0)
            (set! k (+ k 1)))
          (set! i (+ jz 1))
          (while (<= i (+ jz k))
            (set!
              (array-ref f (+ jx i))
              (cast (array-ref math-trig-two-over-pi-limbs (+ jv i)) : f64))
            (set! fw 0.0)
            (set! j 0)
            (while (<= j jx)
              (set!
                fw
                (+
                  fw
                  (*
                    (math-trig-input-limb j x0 x1 x2)
                    (array-ref f (- (+ jx i) j)))))
              (set! j (+ j 1)))
            (set! (array-ref q i) fw)
            (set! i (+ i 1)))
          (set! jz (+ jz k))
          (set! need-recompute true))))
    ;; Normalize the final fractional limbs.
    (if (= z 0.0)
      (begin
        (set! jz (- jz 1))
        (set! q0 (- q0 24))
        (while (= (array-ref iq jz) 0)
          (set! jz (- jz 1))
          (set! q0 (- q0 24))))
      (begin
        (set! z (stdlib.math.f64-scalbn z (- 0 q0)))
        (if (>= z 16777216.0)
          (begin
            (set! fw (cast (cast (* 0.000000059604644775390625 z) : i64) : f64))
            (set! (array-ref iq jz) (cast (- z (* 16777216.0 fw)) : i64))
            (set! jz (+ jz 1))
            (set! q0 (+ q0 24))
            (set! (array-ref iq jz) (cast fw : i64)))
          (set! (array-ref iq jz) (cast z : i64)))))
    ;; Convert integer limbs back to scaled floating values.
    (set! fw (stdlib.math.f64-scalbn 1.0 q0))
    (set! i jz)
    (while (>= i 0)
      (set! (array-ref q i) (* fw (cast (array-ref iq i) : f64)))
      (set! fw (* fw 0.000000059604644775390625))
      (set! i (- i 1)))
    ;; Multiply by the split pi/2 table.
    (set! i jz)
    (while (>= i 0)
      (set! fw 0.0)
      (set! k 0)
      (while (and (<= k jp) (<= k (- jz i)))
        (set!
          fw
          (+
            fw
            (*
              (stdlib.math.f64-from-bits
                (array-ref math-trig-pi-over-two-piece-bits k))
              (array-ref q (+ i k)))))
        (set! k (+ k 1)))
      (set! (array-ref fq (- jz i)) fw)
      (set! i (- i 1)))
    ;; Compress to one term for binary32 or a compensated two-term result
    ;; for binary64.
    (set! fw 0.0)
    (set! i jz)
    (while (>= i 0)
      (set! fw (+ fw (array-ref fq i)))
      (set! i (- i 1)))
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
        (set! i 1)
        (while (<= i jz)
          (set! tail (+ tail (array-ref fq i)))
          (set! i (+ i 1)))
        (MathTrigReduction
          (bit-and n 7)
          (if (= ih 0)
            head
            (- 0.0 head))
          (if (= ih 0)
            tail
            (- 0.0 tail)))))))

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
        (set! fn (+ (* value 0.63661977236758138) 6755399441055744.0))
        (set! fn (- fn 6755399441055744.0))
        (set! n (cast fn : i64))
        (set! r (- value (* fn 1.5707963267341256)))
        (set! w (* fn 6.0771005065061922e-11))
        (if (< (- r w) (- 0.0 0.78539816339744828))
          (begin
            (set! n (- n 1))
            (set! fn (- fn 1.0))
            (set! r (- value (* fn 1.5707963267341256)))
            (set! w (* fn 6.0771005065061922e-11)))
          (when
            (> (- r w) 0.78539816339744828)
            (set! n (+ n 1))
            (set! fn (+ fn 1.0))
            (set! r (- value (* fn 1.5707963267341256)))
            (set! w (* fn 6.0771005065061922e-11))))
        (set! hi (- r w))
        (set! ex (cast (shr ix 20) : i64))
        (set!
          ey
          (cast
            (bit-and (shr (stdlib.math.f64-to-bits hi) 52) (cast 0x7ff : u64))
            : i64))
        (when
          (> (- ex ey) 16)
          (set! t r)
          (set! w (* fn 6.077100506303966e-11))
          (set! r (- t w))
          (set! w (- (* fn 2.0222662487959506e-21) (- (- t r) w)))
          (set! hi (- r w))
          (set!
            ey
            (cast
              (bit-and (shr (stdlib.math.f64-to-bits hi) 52) (cast 0x7ff : u64))
              : i64))
          (when
            (> (- ex ey) 49)
            (set! t r)
            (set! w (* fn 2.0222662487111665e-21))
            (set! r (- t w))
            (set! w (- (* fn 8.4784276603688996e-32) (- (- t r) w)))
            (set! hi (- r w))))
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
          (set! x0 (cast (cast z : i64) : f64))
          (set! z (* (- z x0) 16777216.0))
          (set! x1 (cast (cast z : i64) : f64))
          (set! z (* (- z x1) 16777216.0))
          (set! x2 z)
          (when
            (= x2 0.0)
            (set! nx 2)
            (if (= x1 0.0)
              (set! nx 1)
              unit))
          (set!
            large
            (math-trig-rem-pio2-large
              x0
              x1
              x2
              (- (cast (shr ix 20) : i64) (+ 0x3ff 23))
              nx
              1))
          (if (!= (bit-and bits (cast 0x8000000000000000 : u64)) (cast 0 : u64))
            (MathTrigReduction
              (- 0 large.quadrant)
              (- 0.0 large.hi)
              (- 0.0 large.lo))
            large))))))

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
        (set! fn (+ (* wide 0.63661977236758138) 6755399441055744.0))
        (set! fn (- fn 6755399441055744.0))
        (set! n (cast fn : i64))
        (set!
          remainder
          (- (- wide (* fn 1.5707963109016418)) (* fn 1.5893254773528196e-08)))
        (if (< remainder (- 0.0 0.78539818525314331))
          (begin
            (set! n (- n 1))
            (set! fn (- fn 1.0))
            (set!
              remainder
              (-
                (- wide (* fn 1.5707963109016418))
                (* fn 1.5893254773528196e-08))))
          (when
            (> remainder 0.78539818525314331)
            (set! n (+ n 1))
            (set! fn (+ fn 1.0))
            (set!
              remainder
              (-
                (- wide (* fn 1.5707963109016418))
                (* fn 1.5893254773528196e-08)))))
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
            (MathTrigReduction (- 0 large.quadrant) (- 0.0 large.hi) 0.0)
            large))))))

;; Polynomial kernels on the reduced interval [-pi/4, pi/4].
;: Evaluate the internal binary64 sine kernel on the reduced interval.
(define (math-trig-kernel-sin-f64 [x : f64] [tail : f64] [tail-present : bool]) : f64
  (let
    [z : f64 (* x x)]
    [w : f64 (* z z)]
    [r : f64
      (+
        0.0083333333333224895
        (* z (+ -0.00019841269829857949 (* z 2.7557313707070068e-06)))
        (* z w (+ -2.5050760253406863e-08 (* z 1.5896909952115501e-10))))]
    [v : f64 (* z x)]
    (if tail-present
      (-
        x
        (- (- (* z (- (* 0.5 tail) (* v r))) tail) (* v -0.16666666666666632)))
      (+ x (* v (+ -0.16666666666666632 (* z r)))))))

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
            0.041666666666666602
            (* z (+ -0.001388888888887411 (* z 2.4801587289476729e-05)))))
        (*
          w
          w
          (+
            -2.7557314351390663e-07
            (* z (+ 2.0875723212981748e-09 (* z -1.1359647557788195e-11))))))]
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
    (when
      big
      (when negative (set! x (- 0.0 x)) (set! tail (- 0.0 tail)))
      (set! x (+ (- 0.78539816339744828 x) (- 3.061616997868383e-17 tail)))
      (set! tail 0.0))
    (set! z (* x x))
    (set! w (* z z))
    (set!
      r
      (+
        0.13333333333320124
        (*
          w
          (+
            0.021869488294859542
            (*
              w
              (+
                0.0035920791075913124
                (*
                  w
                  (+
                    0.0005880412408202641
                    (*
                      w
                      (+ 7.8179444293955709e-05 (* w -1.8558637485527546e-05)))))))))))
    (set!
      v
      (*
        z
        (+
          0.053968253976226052
          (*
            w
            (+
              0.0088632398235993001
              (*
                w
                (+
                  0.0014562094543252903
                  (*
                    w
                    (+
                      0.00024646313481846991
                      (*
                        w
                        (+ 7.1407249138260819e-05 (* w 2.5907305186363371e-05))))))))))))
    (set! s (* z x))
    (set! r (+ tail (* z (+ (* s (+ r v)) tail)) (* s 0.33333333333333409)))
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
          (+ a0 (* reciprocal (+ 1.0 (+ (* a0 w0) (* a0 correction))))))))))

;: Evaluate the internal binary32 sine kernel on the reduced interval.
(define (math-trig-kernel-sin-f32 [x : f64]) : f32
  (let
    [z : f64 (* x x)]
    [w : f64 (* z z)]
    [r : f64 (+ -0.00019839334836096632 (* z 2.7183114939898219e-06))]
    [s : f64 (* z x)]
    (cast
      (+
        (+ x (* s (+ -0.16666666641626524 (* z 0.0083333293858894632))))
        (* s w r))
      : f32)))

;: Evaluate the internal binary32 cosine kernel on the reduced interval.
(define (math-trig-kernel-cos-f32 [x : f64]) : f32
  (let
    [z : f64 (* x x)]
    [w : f64 (* z z)]
    [r : f64 (+ -0.0013886763774609929 (* z 2.4390448796277409e-05))]
    (cast
      (+
        (+ (+ 1.0 (* z -0.499999997251031)) (* w 0.041666623323739063))
        (* (* w z) r))
      : f32)))

;: Evaluate tangent or negative cotangent on the reduced binary32 interval.
(define (math-trig-kernel-tan-f32 [x : f64] [odd : bool]) : f32
  (let
    [z : f64 (* x x)]
    [r : f64 (+ 0.002974357433599673 (* z 0.0094656478494367317))]
    [t : f64 (+ 0.053381237844567039 (* z 0.024528318116654728))]
    [w : f64 (* z z)]
    [s : f64 (* z x)]
    [u : f64 (+ 0.3333313950307914 (* z 0.13339200271297674))]
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
          [quadrant : i64 (bit-and reduced.quadrant 3)]
          (cond
            [(= quadrant 0)
              (math-trig-kernel-sin-f64 reduced.hi reduced.lo true)]
            [(= quadrant 1) (math-trig-kernel-cos-f64 reduced.hi reduced.lo)]
            [(= quadrant 2)
              (- 0.0 (math-trig-kernel-sin-f64 reduced.hi reduced.lo true))]
            [else (- 0.0 (math-trig-kernel-cos-f64 reduced.hi reduced.lo))]))))))

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
          [quadrant : i64 (bit-and reduced.quadrant 3)]
          (cond
            [(= quadrant 0) (math-trig-kernel-cos-f64 reduced.hi reduced.lo)]
            [(= quadrant 1)
              (- 0.0 (math-trig-kernel-sin-f64 reduced.hi reduced.lo true))]
            [(= quadrant 2)
              (- 0.0 (math-trig-kernel-cos-f64 reduced.hi reduced.lo))]
            [else (math-trig-kernel-sin-f64 reduced.hi reduced.lo true)]))))))

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
            reduced.hi
            reduced.lo
            (!= (bit-and reduced.quadrant 1) 0)))))))

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
          [quadrant : i64 (bit-and reduced.quadrant 3)]
          (cond
            [(= quadrant 0) (math-trig-kernel-sin-f32 reduced.hi)]
            [(= quadrant 1) (math-trig-kernel-cos-f32 reduced.hi)]
            [(= quadrant 2) (math-trig-kernel-sin-f32 (- 0.0 reduced.hi))]
            [else (- (cast 0.0 : f32) (math-trig-kernel-cos-f32 reduced.hi))]))))))

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
          [quadrant : i64 (bit-and reduced.quadrant 3)]
          (cond
            [(= quadrant 0) (math-trig-kernel-cos-f32 reduced.hi)]
            [(= quadrant 1) (math-trig-kernel-sin-f32 (- 0.0 reduced.hi))]
            [(= quadrant 2)
              (- (cast 0.0 : f32) (math-trig-kernel-cos-f32 reduced.hi))]
            [else (math-trig-kernel-sin-f32 reduced.hi)]))))))

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
            reduced.hi
            (!= (bit-and reduced.quadrant 1) 0)))))))

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

;: Unsigned 192-bit magnitude, low limb first, used by the exact fused
;: multiply-add. 192 bits hold every aligned sum the algorithm forms.
(defstruct MathFmaWide
  (lo u64)
  (mid u64)
  (hi u64))

;: Number of significant bits in `value`; zero has none.
(define (math-fma-u64-bit-length [value : u64]) : i64
  (let
    [rest : u64 value]
    [bits : i64 0]
    (while (not (= rest (cast 0 : u64)))
      (set! rest (shr rest 1))
      (set! bits (+ bits 1)))
    bits))

;: Full 128-bit product of two unsigned 64-bit values.
(define (math-fma-mul-u64 [a : u64] [b : u64]) : MathFmaWide
  (let
    [mask : u64 0xffffffff]
    [a-lo : u64 (bit-and a mask)]
    [a-hi : u64 (shr a 32)]
    [b-lo : u64 (bit-and b mask)]
    [b-hi : u64 (shr b 32)]
    [ll : u64 (* a-lo b-lo)]
    [lh : u64 (* a-lo b-hi)]
    [hl : u64 (* a-hi b-lo)]
    [hh : u64 (* a-hi b-hi)]
    [cross : u64 (+ (+ (shr ll 32) (bit-and lh mask)) (bit-and hl mask))]
    [lo : u64 (bit-or (bit-and ll mask) (shl (bit-and cross mask) 32))]
    [hi : u64 (+ (+ (+ hh (shr lh 32)) (shr hl 32)) (shr cross 32))]
    (MathFmaWide lo hi (cast 0 : u64))))

;: Number of significant bits in a wide magnitude.
(define (math-fma-wide-bit-length [value : MathFmaWide]) : i64
  (if (not (= value.hi (cast 0 : u64)))
    (+ 128 (math-fma-u64-bit-length value.hi))
    (if (not (= value.mid (cast 0 : u64)))
      (+ 64 (math-fma-u64-bit-length value.mid))
      (math-fma-u64-bit-length value.lo))))

;: Shift a wide magnitude left by `count` bits, `0 <= count < 192`. The caller
;: guarantees that no significant bit leaves the 192-bit window.
(define (math-fma-wide-shl [value : MathFmaWide] [count : i64]) : MathFmaWide
  (let
    [limbs : i64 (/ count 64)]
    [bits : i64 (- count (* limbs 64))]
    [zero : u64 0]
    [l0 : u64
      (if (= limbs 0)
        value.lo
        zero)]
    [l1 : u64
      (if (= limbs 0)
        value.mid
        (if (= limbs 1)
          value.lo
          zero))]
    [l2 : u64
      (if (= limbs 0)
        value.hi
        (if (= limbs 1)
          value.mid
          value.lo))]
    (if (= bits 0)
      (MathFmaWide l0 l1 l2)
      (MathFmaWide
        (shl l0 bits)
        (bit-or (shl l1 bits) (shr l0 (- 64 bits)))
        (bit-or (shl l2 bits) (shr l1 (- 64 bits)))))))

;: Low 64 bits of `value` shifted right by `count`, `0 <= count < 192`.
(define (math-fma-wide-shr-low [value : MathFmaWide] [count : i64]) : u64
  (let
    [limbs : i64 (/ count 64)]
    [bits : i64 (- count (* limbs 64))]
    [zero : u64 0]
    [l0 : u64
      (if (= limbs 0)
        value.lo
        (if (= limbs 1)
          value.mid
          value.hi))]
    [l1 : u64
      (if (= limbs 0)
        value.mid
        (if (= limbs 1)
          value.hi
          zero))]
    (if (= bits 0)
      l0
      (bit-or (shr l0 bits) (shl l1 (- 64 bits))))))

;: True when any of the low `below` bits of one limb is set; `below` may lie
;: outside `0..=64`.
(define (math-fma-limb-low-bits-set? [limb : u64] [below : i64]) : bool
  (if (<= below 0)
    false
    (if (>= below 64)
      (not (= limb (cast 0 : u64)))
      (not
        (=
          (bit-and limb (- (shl (cast 1 : u64) below) (cast 1 : u64)))
          (cast 0 : u64))))))

;: True when any of the low `count` bits of `value` is set, `0 <= count <= 192`.
(define (math-fma-wide-low-bits-set? [value : MathFmaWide] [count : i64]) : bool
  (or
    (math-fma-limb-low-bits-set? value.lo count)
    (math-fma-limb-low-bits-set? value.mid (- count 64))
    (math-fma-limb-low-bits-set? value.hi (- count 128))))

;: Sum of two wide magnitudes. The caller guarantees that it fits.
(define (math-fma-wide-add [a : MathFmaWide] [b : MathFmaWide]) : MathFmaWide
  (let
    [zero : u64 0]
    [one : u64 1]
    [lo : u64 (+ a.lo b.lo)]
    [carry-lo : u64
      (if (< lo a.lo)
        one
        zero)]
    [mid-sum : u64 (+ a.mid b.mid)]
    [carry-mid-a : u64
      (if (< mid-sum a.mid)
        one
        zero)]
    [mid : u64 (+ mid-sum carry-lo)]
    [carry-mid-b : u64
      (if (< mid mid-sum)
        one
        zero)]
    (MathFmaWide lo mid (+ (+ (+ a.hi b.hi) carry-mid-a) carry-mid-b))))

;: Difference `a - b` of two wide magnitudes with `a >= b`.
(define (math-fma-wide-sub [a : MathFmaWide] [b : MathFmaWide]) : MathFmaWide
  (let
    [zero : u64 0]
    [one : u64 1]
    [lo : u64 (- a.lo b.lo)]
    [borrow-lo : u64
      (if (< a.lo b.lo)
        one
        zero)]
    [mid-diff : u64 (- a.mid b.mid)]
    [borrow-mid-a : u64
      (if (< a.mid b.mid)
        one
        zero)]
    [mid : u64 (- mid-diff borrow-lo)]
    [borrow-mid-b : u64
      (if (< mid-diff borrow-lo)
        one
        zero)]
    (MathFmaWide lo mid (- (- (- a.hi b.hi) borrow-mid-a) borrow-mid-b))))

;: True when wide magnitude `a` is smaller than `b`.
(define (math-fma-wide-less? [a : MathFmaWide] [b : MathFmaWide]) : bool
  (if (not (= a.hi b.hi))
    (< a.hi b.hi)
    (if (not (= a.mid b.mid))
      (< a.mid b.mid)
      (< a.lo b.lo))))

;: Round the exact value `magnitude * 2^exponent` (nonzero) to a format with
;: `precision` significand bits and `exponent-bits` exponent bits, to nearest
;: with ties to even, and return its encoding with `sign` in the top bit.
(define (math-fma-round
  [sign : u64]
  [magnitude : MathFmaWide]
  [exponent : i64]
  [precision : i64]
  [exponent-bits : i64]) : u64
  (let
    [one : u64 1]
    [bias : i64 (- (shl 1 (- exponent-bits 1)) 1)]
    [quantum-min : i64 (- (- 1 bias) (- precision 1))]
    [max-biased : i64 (- (shl 1 exponent-bits) 1)]
    [sign-bits : u64 (shl sign (- (+ precision exponent-bits) 1))]
    [length : i64 (math-fma-wide-bit-length magnitude)]
    [natural : i64 (- (+ exponent length) precision)]
    [quantum : i64
      (if (< natural quantum-min)
        quantum-min
        natural)]
    [shift : i64 (- quantum exponent)]
    [significand : u64 0]
    (if (<= shift 0)
      ;; The value is already a multiple of the quantum: exact.
      (set! significand (shl (math-fma-wide-shr-low magnitude 0) (- 0 shift)))
      (if (> shift length)
        ;; Entirely below half of the smallest quantum: rounds to zero.
        (set! significand (cast 0 : u64))
        (let
          [kept : u64
            (if (= shift length)
              (cast 0 : u64)
              (math-fma-wide-shr-low magnitude shift))]
          [half? : bool
            (= (bit-and (math-fma-wide-shr-low magnitude (- shift 1)) one) one)]
          [sticky? : bool (math-fma-wide-low-bits-set? magnitude (- shift 1))]
          [odd? : bool (= (bit-and kept one) one)]
          (set!
            significand
            (if (and half? (or sticky? odd?))
              (+ kept one)
              kept)))))
    (when
      (= significand (shl one precision))
      (set! significand (shr significand 1))
      (set! quantum (+ quantum 1)))
    (if (< significand (shl one (- precision 1)))
      ;; Zero or subnormal: the biased exponent field is zero.
      (bit-or sign-bits significand)
      (let
        [biased : i64 (+ (- quantum quantum-min) 1)]
        (if (>= biased max-biased)
          (bit-or sign-bits (shl (cast max-biased : u64) (- precision 1)))
          (bit-or
            sign-bits
            (bit-or
              (shl (cast biased : u64) (- precision 1))
              (- significand (shl one (- precision 1))))))))))

;: Exact `a * b + c` for finite operands with a nonzero product, given as
;: integer significands and the exponents of their lowest bits.
(define (math-fma-finite
  [product-sign : u64]
  [a-significand : u64]
  [a-exponent : i64]
  [b-significand : u64]
  [b-exponent : i64]
  [c-sign : u64]
  [c-significand : u64]
  [c-exponent : i64]
  [precision : i64]
  [exponent-bits : i64]) : u64
  (let
    [zero : u64 0]
    [one : u64 1]
    [product : MathFmaWide (math-fma-mul-u64 a-significand b-significand)]
    [product-exponent : i64 (+ a-exponent b-exponent)]
    (if (= c-significand zero)
      (math-fma-round
        product-sign
        product
        product-exponent
        precision
        exponent-bits)
      (let
        [product-length : i64 (math-fma-wide-bit-length product)]
        [c-length : i64 (math-fma-u64-bit-length c-significand)]
        [product-top : i64 (+ product-exponent product-length)]
        [c-top : i64 (+ c-exponent c-length)]
        ;; An operand that lies entirely below both the other operand's lowest
        ;; bit and a quarter of the smallest quantum the result can have only
        ;; decides inexactness and tie direction. Replace it by one unit three
        ;; bits below that boundary so the aligned sum stays inside 192 bits.
        [c-floor : i64
          (let
            [window : i64 (- (- product-top 1) precision)]
            (if (< product-exponent window)
              product-exponent
              window))]
        [product-floor : i64
          (let
            [window : i64 (- (- c-top 1) precision)]
            (if (< c-exponent window)
              c-exponent
              window))]
        [c-sticky? : bool (<= c-top (- c-floor 2))]
        [product-sticky? : bool (<= product-top (- product-floor 2))]
        [p-mag : MathFmaWide
          (if product-sticky?
            (MathFmaWide one zero zero)
            product)]
        [p-exp : i64
          (if product-sticky?
            (- product-floor 3)
            product-exponent)]
        [c-mag : MathFmaWide
          (if c-sticky?
            (MathFmaWide one zero zero)
            (MathFmaWide c-significand zero zero))]
        [c-exp : i64
          (if c-sticky?
            (- c-floor 3)
            c-exponent)]
        [low-exponent : i64
          (if (< p-exp c-exp)
            p-exp
            c-exp)]
        [p-aligned : MathFmaWide
          (math-fma-wide-shl p-mag (- p-exp low-exponent))]
        [c-aligned : MathFmaWide
          (math-fma-wide-shl c-mag (- c-exp low-exponent))]
        (cond
          [(= product-sign c-sign)
            (math-fma-round
              product-sign
              (math-fma-wide-add p-aligned c-aligned)
              low-exponent
              precision
              exponent-bits)]
          [(math-fma-wide-less? p-aligned c-aligned)
            (math-fma-round
              c-sign
              (math-fma-wide-sub c-aligned p-aligned)
              low-exponent
              precision
              exponent-bits)]
          [(math-fma-wide-less? c-aligned p-aligned)
            (math-fma-round
              product-sign
              (math-fma-wide-sub p-aligned c-aligned)
              low-exponent
              precision
              exponent-bits)]
          ;; Exact cancellation of nonzero terms is positive zero.
          [else zero])))))

;: Fused multiply-add on IEEE-754 encodings with `precision` significand bits
;: and `exponent-bits` exponent bits, zero-extended into `u64`.
(define (math-fma-bits
  [a : u64]
  [b : u64]
  [c : u64]
  [precision : i64]
  [exponent-bits : i64]) : u64
  (let
    [zero : u64 0]
    [one : u64 1]
    [sign-shift : i64 (- (+ precision exponent-bits) 1)]
    [fraction-bits : i64 (- precision 1)]
    [fraction-mask : u64 (- (shl one fraction-bits) one)]
    [exponent-mask : u64 (- (shl one exponent-bits) one)]
    [bias : i64 (- (shl 1 (- exponent-bits 1)) 1)]
    [quantum-min : i64 (- (- 1 bias) fraction-bits)]
    [a-sign : u64 (shr a sign-shift)]
    [b-sign : u64 (shr b sign-shift)]
    [c-sign : u64 (shr c sign-shift)]
    [a-biased : u64 (bit-and (shr a fraction-bits) exponent-mask)]
    [b-biased : u64 (bit-and (shr b fraction-bits) exponent-mask)]
    [c-biased : u64 (bit-and (shr c fraction-bits) exponent-mask)]
    [a-fraction : u64 (bit-and a fraction-mask)]
    [b-fraction : u64 (bit-and b fraction-mask)]
    [c-fraction : u64 (bit-and c fraction-mask)]
    [a-special? : bool (= a-biased exponent-mask)]
    [b-special? : bool (= b-biased exponent-mask)]
    [c-special? : bool (= c-biased exponent-mask)]
    [a-nan? : bool (and a-special? (not (= a-fraction zero)))]
    [b-nan? : bool (and b-special? (not (= b-fraction zero)))]
    [c-nan? : bool (and c-special? (not (= c-fraction zero)))]
    [a-zero? : bool (and (= a-biased zero) (= a-fraction zero))]
    [b-zero? : bool (and (= b-biased zero) (= b-fraction zero))]
    [c-zero? : bool (and (= c-biased zero) (= c-fraction zero))]
    [product-sign : u64 (bit-xor a-sign b-sign)]
    [infinity : u64 (shl exponent-mask fraction-bits)]
    [quiet-nan : u64 (bit-or infinity (shl one (- fraction-bits 1)))]
    (cond
      [(or a-nan? b-nan? c-nan?) quiet-nan]
      [(or a-special? b-special?)
        ;; An infinite product: invalid against a zero factor or an opposite
        ;; infinite addend, otherwise it decides the result.
        (if (or a-zero? b-zero?)
          quiet-nan
          (if (and c-special? (not (= c-sign product-sign)))
            quiet-nan
            (bit-or (shl product-sign sign-shift) infinity)))]
      [c-special? c]
      [(or a-zero? b-zero?)
        ;; An exact zero product leaves `c`; two zeros keep a shared sign and
        ;; are otherwise positive under round-to-nearest.
        (if c-zero?
          (if (= product-sign c-sign)
            (shl product-sign sign-shift)
            zero)
          c)]
      [else
        (let
          [a-significand : u64
            (if (= a-biased zero)
              a-fraction
              (bit-or a-fraction (shl one fraction-bits)))]
          [b-significand : u64
            (if (= b-biased zero)
              b-fraction
              (bit-or b-fraction (shl one fraction-bits)))]
          [c-significand : u64
            (if (= c-biased zero)
              c-fraction
              (bit-or c-fraction (shl one fraction-bits)))]
          [a-exponent : i64
            (if (= a-biased zero)
              quantum-min
              (+ (- (cast a-biased : i64) 1) quantum-min))]
          [b-exponent : i64
            (if (= b-biased zero)
              quantum-min
              (+ (- (cast b-biased : i64) 1) quantum-min))]
          [c-exponent : i64
            (if (= c-biased zero)
              quantum-min
              (+ (- (cast c-biased : i64) 1) quantum-min))]
          (math-fma-finite
            product-sign
            a-significand
            a-exponent
            b-significand
            b-exponent
            c-sign
            c-significand
            c-exponent
            precision
            exponent-bits))])))

;: Return `a * b + c` computed as if with unbounded precision and rounded
;: once to `f64` (round to nearest, ties to even).
;:
;: This is the fused multiply-add of IEEE 754-2019: the product is not
;: rounded before the addition, so the result can differ from
;: `(+ (* a b) c)`, which rounds twice and is never contracted into this
;: operation. Overflow returns the signed infinity and underflow is gradual
;: through subnormals. A NaN operand, an infinite factor times a zero factor,
;: and an infinite product plus the opposite infinity produce NaN; the sign and
;: payload of a NaN result are not part of the contract. When the exact value
;: is zero the result is negative zero only if the product is a negative zero
;: and `c` is negative zero; nonzero terms that cancel exactly give positive
;: zero. A nonzero exact value that underflows to zero keeps its sign. The
;: implementation is pure integer arithmetic: it allocates nothing and uses no
;: runtime, libc, libm, or FMA instruction, so every target returns the same
;: bits.
(define (f64-mul-add [a : f64] [b : f64] [c : f64]) : f64
  (stdlib.math.f64-from-bits
    (math-fma-bits
      (stdlib.math.f64-to-bits a)
      (stdlib.math.f64-to-bits b)
      (stdlib.math.f64-to-bits c)
      53
      11)))

;: Binary32 fused multiply-add: `a * b + c` rounded once to `f32`.
;:
;: Behavior matches `f64-mul-add` at binary32 precision.
(define (f32-mul-add [a : f32] [b : f32] [c : f32]) : f32
  (stdlib.math.f32-from-bits
    (cast
      (math-fma-bits
        (cast (stdlib.math.f32-to-bits a) : u64)
        (cast (stdlib.math.f32-to-bits b) : u64)
        (cast (stdlib.math.f32-to-bits c) : u64)
        24
        8)
      : u32)))

;: Return the fused multiply-add of three `f64` or three `f32` expressions,
;: preserving their type.
;:
;: Each expression is evaluated exactly once, left to right. Mixed or other
;: operand types are rejected with a compile-time diagnostic.
(defmacro (mul-add [a : comptime.Expr] [b : comptime.Expr] [c : comptime.Expr]) : comptime.Expr
  (match (type-kind (comptime.expr-type a))
    ["f64"
      (match (type-kind (comptime.expr-type b))
        ["f64"
          (match (type-kind (comptime.expr-type c))
            ["f64" `(stdlib.math.f64-mul-add ,a ,b ,c)]
            [_
              (comptime.comptime-error
                (comptime.string-append
                  "math.mul-add: operand types must match f64, found "
                  (type-kind (comptime.expr-type c))))])]
        [_
          (comptime.comptime-error
            (comptime.string-append
              "math.mul-add: operand types must match f64, found "
              (type-kind (comptime.expr-type b))))])]
    ["f32"
      (match (type-kind (comptime.expr-type b))
        ["f32"
          (match (type-kind (comptime.expr-type c))
            ["f32" `(stdlib.math.f32-mul-add ,a ,b ,c)]
            [_
              (comptime.comptime-error
                (comptime.string-append
                  "math.mul-add: operand types must match f32, found "
                  (type-kind (comptime.expr-type c))))])]
        [_
          (comptime.comptime-error
            (comptime.string-append
              "math.mul-add: operand types must match f32, found "
              (type-kind (comptime.expr-type b))))])]
    [_
      (comptime.comptime-error
        (comptime.string-append
          "math.mul-add: expected f64 or f32, found "
          (type-kind (comptime.expr-type a))))]))

;; Inline test coverage.
(cfg test (import stdlib.test))

(test
  math-trig-reduction-and-special-values
  (let
    [pi : f64 (stdlib.math.f64-from-bits 0x400921fb54442d18)]
    [max64 : f64 (stdlib.math.f64-from-bits 0x7fefffffffffffff)]
    [max32 : f32 (stdlib.math.f32-from-bits (cast 0x7f7fffff : u32))]
    [medium : MathTrigReduction (stdlib.math.math-trig-rem-pio2-f64 pi)]
    [large64 : MathTrigReduction (stdlib.math.math-trig-rem-pio2-f64 max64)]
    [large32 : MathTrigReduction (stdlib.math.math-trig-rem-pio2-f32 max32)]
    [negative-zero64 : f64
      (stdlib.math.f64-from-bits (cast 0x8000000000000000 : u64))]
    [negative-zero32 : f32 (stdlib.math.f32-from-bits (cast 0x80000000 : u32))]
    (test.assert-true
      (and
        (= (bit-and medium.quadrant 3) 2)
        (<= (stdlib.math.f64-abs medium.hi) 0.785398164)
        (<= (stdlib.math.f64-abs medium.lo) 0.000000000000001)
        (<= (stdlib.math.f64-abs large64.hi) 0.785398164)
        (stdlib.math.f64-finite? large64.hi)
        (stdlib.math.f64-finite? large64.lo)
        (<= (stdlib.math.f64-abs large32.hi) 0.785398164)
        (stdlib.math.f64-finite? large32.hi))
      "math-trig-reduction-and-special-values: (and (= (bit-and medium.quadrant 3) 2) (<= (f64-abs mediu...")
    (test.assert-true
      (=
        (stdlib.math.f64-to-bits (stdlib.math.f64-sin pi))
        (cast 0x3ca1a62633145c07 : u64))
      "math-trig-reduction-and-special-values: (= (f64-to-bits (f64-sin pi)) (cast 0x3ca1a62633145c07 : ...")
    (test.assert-true
      (= (stdlib.math.f64-cos pi) -1.0)
      "math-trig-reduction-and-special-values: (= (f64-cos pi) -1.0)")
    (test.assert-true
      (=
        (stdlib.math.f64-to-bits (stdlib.math.f64-sin negative-zero64))
        (cast 0x8000000000000000 : u64))
      "math-trig-reduction-and-special-values: (= (f64-to-bits (f64-sin negative-zero64)) (cast 0x800000...")
    (test.assert-true
      (=
        (stdlib.math.f64-to-bits (stdlib.math.f64-tan negative-zero64))
        (cast 0x8000000000000000 : u64))
      "math-trig-reduction-and-special-values: (= (f64-to-bits (f64-tan negative-zero64)) (cast 0x800000...")
    (test.assert-true
      (=
        (stdlib.math.f32-to-bits (stdlib.math.f32-sin negative-zero32))
        (cast 0x80000000 : u32))
      "math-trig-reduction-and-special-values: (= (f32-to-bits (f32-sin negative-zero32)) (cast 0x800000...")
    (test.assert-true
      (=
        (stdlib.math.f32-to-bits (stdlib.math.f32-tan negative-zero32))
        (cast 0x80000000 : u32))
      "math-trig-reduction-and-special-values: (= (f32-to-bits (f32-tan negative-zero32)) (cast 0x800000...")
    (test.assert-true
      (and
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
      "math-trig-reduction-and-special-values: (and (f64-nan? (f64-sin (f64-positive-infinity))) (f64-na...")))

(test
  math-i64-api
  (test.assert-true
    (= (stdlib.math.i64-abs -7) 7)
    "math-i64-api: (= (i64-abs -7) 7)")
  (test.assert-true
    (= (stdlib.math.i64-abs 0) 0)
    "math-i64-api: (= (i64-abs 0) 0)")
  (test.assert-true
    (= (stdlib.math.i64-abs 7) 7)
    "math-i64-api: (= (i64-abs 7) 7)")
  (test.assert-true
    (= (stdlib.math.i64-abs -9223372036854775808) -9223372036854775808)
    "math-i64-api: (= (i64-abs -9223372036854775808) -9223372036854775808)")
  (test.assert-true
    (=
      (stdlib.math.i64-abs-or -9223372036854775808 9223372036854775807)
      9223372036854775807)
    "math-i64-api: (= (i64-abs-or -9223372036854775808 9223372036854775807) ...")
  (test.assert-true
    (= (stdlib.math.i64-min -3 9) -3)
    "math-i64-api: (= (i64-min -3 9) -3)")
  (test.assert-true
    (= (stdlib.math.i64-max -3 9) 9)
    "math-i64-api: (= (i64-max -3 9) 9)")
  (test.assert-true
    (= (stdlib.math.i64-clamp 5 0 10) 5)
    "math-i64-api: (= (i64-clamp 5 0 10) 5)")
  (test.assert-true
    (= (stdlib.math.i64-clamp -1 0 10) 0)
    "math-i64-api: (= (i64-clamp -1 0 10) 0)")
  (test.assert-true
    (= (stdlib.math.i64-clamp 11 0 10) 10)
    "math-i64-api: (= (i64-clamp 11 0 10) 10)")
  (test.assert-true
    (= (stdlib.math.i64-clamp -1 10 0) 0)
    "math-i64-api: (= (i64-clamp -1 10 0) 0)")
  (test.assert-true
    (= (stdlib.math.i64-clamp 11 10 0) 10)
    "math-i64-api: (= (i64-clamp 11 10 0) 10)")
  (test.assert-true
    (stdlib.math.i64-negative? -1)
    "math-i64-api: (i64-negative? -1)")
  (test.assert-true (stdlib.math.i64-zero? 0) "math-i64-api: (i64-zero? 0)")
  (test.assert-true
    (stdlib.math.i64-positive? 1)
    "math-i64-api: (i64-positive? 1)")
  (test.assert-true
    (not (stdlib.math.i64-positive? 0))
    "math-i64-api: (not (i64-positive? 0))"))

(test
  math-f64-api
  (let
    [abs-neg : f64 -2.5]
    [abs-want : f64 2.5]
    (test.assert-true
      (= (stdlib.math.f64-abs -2.5) 2.5)
      "math-f64-api: (= (f64-abs -2.5) 2.5)")
    (test.assert-true
      (= (stdlib.math.f64-abs 0.0) 0.0)
      "math-f64-api: (= (f64-abs 0.0) 0.0)")
    (test.assert-true
      (= (stdlib.math.f64-abs 2.5) 2.5)
      "math-f64-api: (= (f64-abs 2.5) 2.5)")
    (test.assert-true
      (= (stdlib.math.abs abs-neg) abs-want)
      "math-f64-api: (= (abs abs-neg) abs-want)")
    (test.assert-true
      (= (stdlib.math.f64-min -3.5 9.25) -3.5)
      "math-f64-api: (= (f64-min -3.5 9.25) -3.5)")
    (test.assert-true
      (= (stdlib.math.f64-max -3.5 9.25) 9.25)
      "math-f64-api: (= (f64-max -3.5 9.25) 9.25)")
    (test.assert-true
      (= (stdlib.math.f64-clamp 5.5 0.0 10.0) 5.5)
      "math-f64-api: (= (f64-clamp 5.5 0.0 10.0) 5.5)")
    (test.assert-true
      (= (stdlib.math.f64-clamp -1.0 0.0 10.0) 0.0)
      "math-f64-api: (= (f64-clamp -1.0 0.0 10.0) 0.0)")
    (test.assert-true
      (= (stdlib.math.f64-clamp 11.0 0.0 10.0) 10.0)
      "math-f64-api: (= (f64-clamp 11.0 0.0 10.0) 10.0)")
    (test.assert-true
      (= (stdlib.math.f64-clamp 11.0 10.0 0.0) 10.0)
      "math-f64-api: (= (f64-clamp 11.0 10.0 0.0) 10.0)")
    (test.assert-true
      (stdlib.math.f64-negative? -0.5)
      "math-f64-api: (f64-negative? -0.5)")
    (test.assert-true
      (stdlib.math.f64-zero? 0.0)
      "math-f64-api: (f64-zero? 0.0)")
    (test.assert-true
      (stdlib.math.f64-positive? 0.5)
      "math-f64-api: (f64-positive? 0.5)")
    (test.assert-true
      (not (stdlib.math.f64-negative? 0.0))
      "math-f64-api: (not (f64-negative? 0.0))")))

(test
  math-f32-api
  (let
    [neg : f32 -2.5]
    [zero : f32 0.0]
    [pos : f32 2.5]
    [want : f32 2.5]
    (test.assert-true
      (= (stdlib.math.f32-abs neg) want)
      "math-f32-api: (= (f32-abs neg) want)")
    (test.assert-true
      (= (stdlib.math.f32-abs zero) zero)
      "math-f32-api: (= (f32-abs zero) zero)")
    (test.assert-true
      (= (stdlib.math.f32-abs pos) want)
      "math-f32-api: (= (f32-abs pos) want)")
    (test.assert-true
      (= (stdlib.math.abs neg) want)
      "math-f32-api: (= (abs neg) want)")))

(test
  math-float-sqrt
  (let
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
    (test.assert-true
      (and
        (= calls 1)
        (= once 4.0)
        (= sqrt32 (stdlib.math.f32-sqrt four32))
        (= (stdlib.math.f64-sqrt 81.0) 9.0)
        (= (stdlib.math.f32-sqrt one32) one32))
      "math-float-sqrt: (and (= calls 1) (= once 4.0) (= sqrt32 (f32-sqrt four32)...")
    (test.assert-true
      (=
        (stdlib.math.f64-to-bits (stdlib.math.f64-sqrt 2.0))
        (cast 0x3ff6a09e667f3bcd : u64))
      "math-float-sqrt: (= (f64-to-bits (f64-sqrt 2.0)) (cast 0x3ff6a09e667f3bcd ...")
    (test.assert-true
      (=
        (stdlib.math.f64-to-bits (stdlib.math.f64-sqrt 3.0))
        (cast 0x3ffbb67ae8584caa : u64))
      "math-float-sqrt: (= (f64-to-bits (f64-sqrt 3.0)) (cast 0x3ffbb67ae8584caa ...")
    (test.assert-true
      (=
        (stdlib.math.f64-to-bits (stdlib.math.f64-sqrt 10.0))
        (cast 0x40094c583ada5b53 : u64))
      "math-float-sqrt: (= (f64-to-bits (f64-sqrt 10.0)) (cast 0x40094c583ada5b53...")
    (test.assert-true
      (=
        (stdlib.math.f64-to-bits
          (stdlib.math.f64-sqrt
            (stdlib.math.f64-from-bits (cast 0x3fb999999999999a : u64))))
        (cast 0x3fd43d136248490f : u64))
      "math-float-sqrt: (= (f64-to-bits (f64-sqrt (f64-from-bits (cast 0x3fb99999...")
    (test.assert-true
      (=
        (stdlib.math.f64-to-bits
          (stdlib.math.f64-sqrt (stdlib.math.f64-from-bits (cast 1 : u64))))
        (cast 0x1e60000000000000 : u64))
      "math-float-sqrt: (= (f64-to-bits (f64-sqrt (f64-from-bits (cast 1 : u64)))...")
    (test.assert-true
      (=
        (stdlib.math.f64-to-bits
          (stdlib.math.f64-sqrt
            (stdlib.math.f64-from-bits (cast 0x000fffffffffffff : u64))))
        (cast 0x1fffffffffffffff : u64))
      "math-float-sqrt: (= (f64-to-bits (f64-sqrt (f64-from-bits (cast 0x000fffff...")
    (test.assert-true
      (=
        (stdlib.math.f64-to-bits
          (stdlib.math.f64-sqrt
            (stdlib.math.f64-from-bits (cast 0x0010000000000000 : u64))))
        (cast 0x2000000000000000 : u64))
      "math-float-sqrt: (= (f64-to-bits (f64-sqrt (f64-from-bits (cast 0x00100000...")
    (test.assert-true
      (=
        (stdlib.math.f64-to-bits
          (stdlib.math.f64-sqrt
            (stdlib.math.f64-from-bits (cast 0x7fefffffffffffff : u64))))
        (cast 0x5fefffffffffffff : u64))
      "math-float-sqrt: (= (f64-to-bits (f64-sqrt (f64-from-bits (cast 0x7fefffff...")
    (test.assert-true
      (=
        (stdlib.math.f32-to-bits
          (stdlib.math.f32-sqrt
            (stdlib.math.f32-from-bits (cast 0x40000000 : u32))))
        (cast 0x3fb504f3 : u32))
      "math-float-sqrt: (= (f32-to-bits (f32-sqrt (f32-from-bits (cast 0x40000000...")
    (test.assert-true
      (=
        (stdlib.math.f32-to-bits
          (stdlib.math.f32-sqrt
            (stdlib.math.f32-from-bits (cast 0x40400000 : u32))))
        (cast 0x3fddb3d7 : u32))
      "math-float-sqrt: (= (f32-to-bits (f32-sqrt (f32-from-bits (cast 0x40400000...")
    (test.assert-true
      (=
        (stdlib.math.f32-to-bits
          (stdlib.math.f32-sqrt
            (stdlib.math.f32-from-bits (cast 0x41200000 : u32))))
        (cast 0x404a62c2 : u32))
      "math-float-sqrt: (= (f32-to-bits (f32-sqrt (f32-from-bits (cast 0x41200000...")
    (test.assert-true
      (=
        (stdlib.math.f32-to-bits
          (stdlib.math.f32-sqrt
            (stdlib.math.f32-from-bits (cast 0x3dcccccd : u32))))
        (cast 0x3ea1e89b : u32))
      "math-float-sqrt: (= (f32-to-bits (f32-sqrt (f32-from-bits (cast 0x3dcccccd...")
    (test.assert-true
      (=
        (stdlib.math.f32-to-bits
          (stdlib.math.f32-sqrt (stdlib.math.f32-from-bits (cast 1 : u32))))
        (cast 0x1a3504f3 : u32))
      "math-float-sqrt: (= (f32-to-bits (f32-sqrt (f32-from-bits (cast 1 : u32)))...")
    (test.assert-true
      (=
        (stdlib.math.f32-to-bits
          (stdlib.math.f32-sqrt
            (stdlib.math.f32-from-bits (cast 0x007fffff : u32))))
        (cast 0x1fffffff : u32))
      "math-float-sqrt: (= (f32-to-bits (f32-sqrt (f32-from-bits (cast 0x007fffff...")
    (test.assert-true
      (=
        (stdlib.math.f32-to-bits
          (stdlib.math.f32-sqrt
            (stdlib.math.f32-from-bits (cast 0x00800000 : u32))))
        (cast 0x20000000 : u32))
      "math-float-sqrt: (= (f32-to-bits (f32-sqrt (f32-from-bits (cast 0x00800000...")
    (test.assert-true
      (=
        (stdlib.math.f32-to-bits
          (stdlib.math.f32-sqrt
            (stdlib.math.f32-from-bits (cast 0x7f7fffff : u32))))
        (cast 0x5f7fffff : u32))
      "math-float-sqrt: (= (f32-to-bits (f32-sqrt (f32-from-bits (cast 0x7f7fffff...")
    (test.assert-true
      (and
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
      "math-float-sqrt: (and (= (f64-to-bits (f64-sqrt (f64-from-bits (cast 0 : u...")
    (test.assert-true
      (and
        (stdlib.math.f64-nan? (stdlib.math.f64-sqrt -1.0))
        (stdlib.math.f64-nan?
          (stdlib.math.f64-sqrt (stdlib.math.f64-negative-infinity)))
        (stdlib.math.f64-nan? (stdlib.math.f64-sqrt nan64))
        (stdlib.math.f32-nan?
          (stdlib.math.f32-sqrt (stdlib.math.f32-negative-infinity)))
        (stdlib.math.f32-nan? (stdlib.math.f32-sqrt nan32)))
      "math-float-sqrt: (and (f64-nan? (f64-sqrt -1.0)) (f64-nan? (f64-sqrt (f64-...")))

(test
  math-float-mul-add
  (let
    [x : f64 (stdlib.math.f64-from-bits 0x3ff0000000400000)]
    [minus-one : f64 -1.0]
    [x32 : f32 (stdlib.math.f32-from-bits (cast 0x3f800200 : u32))]
    [minus-one32 : f32 -1.0]
    [max : f64 (stdlib.math.f64-from-bits 0x7fefffffffffffff)]
    [min-subnormal : f64 (stdlib.math.f64-from-bits 0x0000000000000001)]
    [negative-zero : f64 (stdlib.math.f64-from-bits 0x8000000000000000)]
    ;; One rounding keeps the 2^-60 term that the rounded product loses.
    (test.assert-true
      (=
        (stdlib.math.f64-to-bits (stdlib.math.f64-mul-add x x minus-one))
        0x3e20000000200000)
      "math-float-mul-add: (= (f64-to-bits (f64-mul-add x x minus-one)) 0x3e20000000...")
    (test.assert-true
      (= (stdlib.math.f64-to-bits (+ (* x x) minus-one)) 0x3e20000000000000)
      "math-float-mul-add: (= (f64-to-bits (+ (* x x) minus-one)) 0x3e20000000000000)")
    (test.assert-true
      (=
        (stdlib.math.f32-to-bits (stdlib.math.mul-add x32 x32 minus-one32))
        (cast 0x39000100 : u32))
      "math-float-mul-add: (= (f32-to-bits (mul-add x32 x32 minus-one32)) (cast 0x39...")
    ;; The exact sum is finite although the product alone overflows.
    (test.assert-true
      (=
        (stdlib.math.f64-to-bits (stdlib.math.mul-add max 2.0 (- 0.0 max)))
        0x7fefffffffffffff)
      "math-float-mul-add: (= (f64-to-bits (mul-add max 2.0 (- 0.0 max))) 0x7fefffff...")
    ;; Half of the smallest subnormal ties to even, which is zero.
    (test.assert-true
      (=
        (stdlib.math.f64-to-bits
          (stdlib.math.f64-mul-add min-subnormal 0.5 0.0))
        0)
      "math-float-mul-add: (= (f64-to-bits (f64-mul-add min-subnormal 0.5 0.0)) 0)")
    ;; Signed zeros, exact cancellation, and invalid operations.
    (test.assert-true
      (=
        (stdlib.math.f64-to-bits
          (stdlib.math.f64-mul-add negative-zero 5.0 negative-zero))
        0x8000000000000000)
      "math-float-mul-add: (= (f64-to-bits (f64-mul-add negative-zero 5.0 negative-z...")
    (test.assert-true
      (= (stdlib.math.f64-to-bits (stdlib.math.f64-mul-add 3.0 5.0 -15.0)) 0)
      "math-float-mul-add: (= (f64-to-bits (f64-mul-add 3.0 5.0 -15.0)) 0)")
    (test.assert-true
      (stdlib.math.f64-nan?
        (stdlib.math.f64-mul-add (stdlib.math.f64-positive-infinity) 0.0 1.0))
      "math-float-mul-add: (f64-nan? (f64-mul-add (f64-positive-infinity) 0.0 1.0))")
    (test.assert-true
      (stdlib.math.f64-nan?
        (stdlib.math.f64-mul-add
          (stdlib.math.f64-positive-infinity)
          1.0
          (stdlib.math.f64-negative-infinity)))
      "math-float-mul-add: (f64-nan? (f64-mul-add (f64-positive-infinity) 1.0 (f64-n...")
    (test.assert-true
      (=
        (stdlib.math.f64-mul-add 2.0 3.0 (stdlib.math.f64-negative-infinity))
        (stdlib.math.f64-negative-infinity))
      "math-float-mul-add: (= (f64-mul-add 2.0 3.0 (f64-negative-infinity)) (f64-neg...")))

(test
  math-float-exp
  (let
    [calls : i64 0]
    [once : f64
      (stdlib.math.exp
        (begin
          (set! calls (+ calls 1))
          1.0))]
    [one32 : f32 1.0]
    [exp32 : f32 (stdlib.math.exp one32)]
    (test.assert-true
      (and
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
      "math-float-exp: (and (= calls 1) (= (f64-to-bits once) (cast 0x4005bf0a8b...")))

(test
  math-float-log
  (let
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
    (test.assert-true
      (and
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
      "math-float-log: (and (= calls 1) (= (f64-to-bits once) (cast 0x3fe62e42fe...")))

(test
  math-f64-ieee-foundation
  (let
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
    (test.assert-true
      (= (stdlib.math.f64-to-bits positive-zero) (cast 0 : u64))
      "math-f64-ieee-foundation: (= (f64-to-bits positive-zero) (cast 0 : u64))")
    (test.assert-true
      (=
        (stdlib.math.f64-to-bits negative-zero)
        (cast 0x8000000000000000 : u64))
      "math-f64-ieee-foundation: (= (f64-to-bits negative-zero) (cast 0x8000000000000000 :...")
    (test.assert-true
      (=
        (stdlib.math.f64-to-bits max-subnormal)
        (cast 0x000fffffffffffff : u64))
      "math-f64-ieee-foundation: (= (f64-to-bits max-subnormal) (cast 0x000fffffffffffff :...")
    (test.assert-true
      (= (stdlib.math.f64-to-bits min-normal) (cast 0x0010000000000000 : u64))
      "math-f64-ieee-foundation: (= (f64-to-bits min-normal) (cast 0x0010000000000000 : u64))")
    (test.assert-true
      (= (stdlib.math.f64-to-bits max-finite) (cast 0x7fefffffffffffff : u64))
      "math-f64-ieee-foundation: (= (f64-to-bits max-finite) (cast 0x7fefffffffffffff : u64))")
    (test.assert-true
      (= (stdlib.math.f64-to-bits payload-nan) (cast 0x7ff8000000001234 : u64))
      "math-f64-ieee-foundation: (= (f64-to-bits payload-nan) (cast 0x7ff8000000001234 : u...")
    (test.assert-true
      (and
        (stdlib.math.f64-positive-zero? positive-zero)
        (stdlib.math.f64-negative-zero? negative-zero)
        (stdlib.math.f64-signed-zero? negative-zero)
        (stdlib.math.f64-sign-bit? negative-zero)
        (not (stdlib.math.f64-sign-bit? positive-zero)))
      "math-f64-ieee-foundation: (and (f64-positive-zero? positive-zero) (f64-negative-zer...")
    (test.assert-true
      (and
        (stdlib.math.f64-subnormal? min-subnormal)
        (stdlib.math.f64-subnormal? max-subnormal)
        (stdlib.math.f64-normal? min-normal)
        (stdlib.math.f64-finite? max-finite)
        (stdlib.math.f64-infinite? (stdlib.math.f64-positive-infinity))
        (stdlib.math.f64-infinite? (stdlib.math.f64-negative-infinity))
        (stdlib.math.f64-nan? payload-nan))
      "math-f64-ieee-foundation: (and (f64-subnormal? min-subnormal) (f64-subnormal? max-s...")
    (test.assert-true
      (=
        (stdlib.math.f64-to-bits (stdlib.math.f64-copy-sign 3.0 negative-zero))
        (cast 0xc008000000000000 : u64))
      "math-f64-ieee-foundation: (= (f64-to-bits (f64-copy-sign 3.0 negative-zero)) (cast ...")
    (test.assert-true
      (= (stdlib.math.f64-to-bits (stdlib.math.f64-abs negative-zero)) 0)
      "math-f64-ieee-foundation: (= (f64-to-bits (f64-abs negative-zero)) 0)")
    (test.assert-true
      (= (stdlib.math.f64-scalbn 1.5 3) 12.0)
      "math-f64-ieee-foundation: (= (f64-scalbn 1.5 3) 12.0)")
    (test.assert-true
      (=
        (stdlib.math.f64-to-bits (stdlib.math.f64-scalbn min-normal -1))
        (cast 0x0008000000000000 : u64))
      "math-f64-ieee-foundation: (= (f64-to-bits (f64-scalbn min-normal -1)) (cast 0x00080...")
    (test.assert-true
      (=
        (stdlib.math.f64-to-bits (stdlib.math.f64-scalbn 1.0 -1074))
        (cast 1 : u64))
      "math-f64-ieee-foundation: (= (f64-to-bits (f64-scalbn 1.0 -1074)) (cast 1 : u64))")
    (test.assert-true
      (=
        (stdlib.math.f64-to-bits (stdlib.math.f64-scalbn 1.0 -1075))
        (cast 0 : u64))
      "math-f64-ieee-foundation: (= (f64-to-bits (f64-scalbn 1.0 -1075)) (cast 0 : u64))")
    (test.assert-true
      (=
        (stdlib.math.f64-to-bits (stdlib.math.f64-scalbn 3.0 -1075))
        (cast 2 : u64))
      "math-f64-ieee-foundation: (= (f64-to-bits (f64-scalbn 3.0 -1075)) (cast 2 : u64))")
    (test.assert-true
      (=
        (stdlib.math.f64-to-bits (stdlib.math.f64-scalbn -1.0 -1075))
        (cast 0x8000000000000000 : u64))
      "math-f64-ieee-foundation: (= (f64-to-bits (f64-scalbn -1.0 -1075)) (cast 0x80000000...")
    (test.assert-true
      (stdlib.math.f64-infinite? (stdlib.math.f64-scalbn max-finite 1))
      "math-f64-ieee-foundation: (f64-infinite? (f64-scalbn max-finite 1))")
    (test.assert-true
      (=
        (stdlib.math.f64-to-bits
          (stdlib.math.f64-scalbn (stdlib.math.f64-positive-infinity) -99))
        (cast 0x7ff0000000000000 : u64))
      "math-f64-ieee-foundation: (= (f64-to-bits (f64-scalbn (f64-positive-infinity) -99))...")
    (test.assert-true
      (stdlib.math.f64-nan? (stdlib.math.f64-scalbn payload-nan 99))
      "math-f64-ieee-foundation: (f64-nan? (f64-scalbn payload-nan 99))")))

(test
  math-f32-ieee-foundation
  (let
    [positive-zero : f32 (stdlib.math.f32-from-bits (cast 0 : u32))]
    [negative-zero : f32 (stdlib.math.f32-from-bits (cast 0x80000000 : u32))]
    [min-subnormal : f32 (stdlib.math.f32-from-bits (cast 1 : u32))]
    [max-subnormal : f32 (stdlib.math.f32-from-bits (cast 0x007fffff : u32))]
    [min-normal : f32 (stdlib.math.f32-from-bits (cast 0x00800000 : u32))]
    [max-finite : f32 (stdlib.math.f32-from-bits (cast 0x7f7fffff : u32))]
    [payload-nan : f32 (stdlib.math.f32-from-bits (cast 0x7fc01234 : u32))]
    [one : f32 1.0]
    [three : f32 3.0]
    (test.assert-true
      (= (stdlib.math.f32-to-bits negative-zero) (cast 0x80000000 : u32))
      "math-f32-ieee-foundation: (= (f32-to-bits negative-zero) (cast 0x80000000 : u32))")
    (test.assert-true
      (= (stdlib.math.f32-to-bits max-subnormal) (cast 0x007fffff : u32))
      "math-f32-ieee-foundation: (= (f32-to-bits max-subnormal) (cast 0x007fffff : u32))")
    (test.assert-true
      (= (stdlib.math.f32-to-bits min-normal) (cast 0x00800000 : u32))
      "math-f32-ieee-foundation: (= (f32-to-bits min-normal) (cast 0x00800000 : u32))")
    (test.assert-true
      (= (stdlib.math.f32-to-bits max-finite) (cast 0x7f7fffff : u32))
      "math-f32-ieee-foundation: (= (f32-to-bits max-finite) (cast 0x7f7fffff : u32))")
    (test.assert-true
      (= (stdlib.math.f32-to-bits payload-nan) (cast 0x7fc01234 : u32))
      "math-f32-ieee-foundation: (= (f32-to-bits payload-nan) (cast 0x7fc01234 : u32))")
    (test.assert-true
      (and
        (stdlib.math.f32-positive-zero? positive-zero)
        (stdlib.math.f32-negative-zero? negative-zero)
        (stdlib.math.f32-sign-bit? negative-zero)
        (stdlib.math.f32-subnormal? min-subnormal)
        (stdlib.math.f32-subnormal? max-subnormal)
        (stdlib.math.f32-normal? min-normal)
        (stdlib.math.f32-finite? max-finite)
        (stdlib.math.f32-infinite? (stdlib.math.f32-positive-infinity))
        (stdlib.math.f32-nan? payload-nan))
      "math-f32-ieee-foundation: (and (f32-positive-zero? positive-zero) (f32-negative-zer...")
    (test.assert-true
      (= (stdlib.math.f32-to-bits (stdlib.math.f32-abs negative-zero)) 0)
      "math-f32-ieee-foundation: (= (f32-to-bits (f32-abs negative-zero)) 0)")
    (test.assert-true
      (=
        (stdlib.math.f32-to-bits (stdlib.math.f32-scalbn min-normal -1))
        (cast 0x00400000 : u32))
      "math-f32-ieee-foundation: (= (f32-to-bits (f32-scalbn min-normal -1)) (cast 0x00400...")
    (test.assert-true
      (=
        (stdlib.math.f32-to-bits (stdlib.math.f32-scalbn one -149))
        (cast 1 : u32))
      "math-f32-ieee-foundation: (= (f32-to-bits (f32-scalbn one -149)) (cast 1 : u32))")
    (test.assert-true
      (=
        (stdlib.math.f32-to-bits (stdlib.math.f32-scalbn one -150))
        (cast 0 : u32))
      "math-f32-ieee-foundation: (= (f32-to-bits (f32-scalbn one -150)) (cast 0 : u32))")
    (test.assert-true
      (=
        (stdlib.math.f32-to-bits (stdlib.math.f32-scalbn three -150))
        (cast 2 : u32))
      "math-f32-ieee-foundation: (= (f32-to-bits (f32-scalbn three -150)) (cast 2 : u32))")
    (test.assert-true
      (=
        (stdlib.math.f32-to-bits (stdlib.math.f32-scalbn negative-zero 1000))
        (cast 0x80000000 : u32))
      "math-f32-ieee-foundation: (= (f32-to-bits (f32-scalbn negative-zero 1000)) (cast 0x...")
    (test.assert-true
      (stdlib.math.f32-infinite? (stdlib.math.f32-scalbn max-finite 1))
      "math-f32-ieee-foundation: (f32-infinite? (f32-scalbn max-finite 1))")
    (test.assert-true
      (stdlib.math.f32-nan? (stdlib.math.f32-scalbn payload-nan 99))
      "math-f32-ieee-foundation: (f32-nan? (f32-scalbn payload-nan 99))")))

(test
  math-float-pow
  (let
    [calls : i64 0]
    [ycalls : i64 0]
    [once : f64
      (stdlib.math.pow
        (begin
          (set! calls (+ calls 1))
          2.0)
        10.0)]
    [once-y : f64
      (stdlib.math.pow
        3.0
        (begin
          (set! ycalls (+ ycalls 1))
          2.0))]
    [two32 : f32 2.0]
    [ten32 : f32 10.0]
    [pow32 : f32 (stdlib.math.pow two32 ten32)]
    (test.assert-true
      (and
        (= calls 1)
        (= ycalls 1)
        (= (stdlib.math.f64-to-bits once) (cast 0x4090000000000000 : u64))
        (= (stdlib.math.f64-to-bits once-y) (cast 0x4022000000000000 : u64))
        (= (stdlib.math.f32-to-bits pow32) (cast 0x44800000 : u32)))
      "math-float-pow: (and (= calls 1) (= ycalls 1) (= (f64-to-bits once) (cast...")))

;; NaN-propagation power cases. The rest of the decision table (and its MPFR
;; 800-bit reference results) lives in tests/integration/stdlib_math_pow.tl.
(test
  math-pow-f64-special
  (test.assert-true
    (stdlib.math.f64-nan?
      (stdlib.math.f64-pow
        (stdlib.math.f64-from-bits (cast 0x7ff8000000000000 : u64))
        (stdlib.math.f64-from-bits (cast 0x4000000000000000 : u64))))
    "math-pow-f64-special: (f64-nan? (f64-pow (f64-from-bits (cast 0x7ff800000000000...")
  (test.assert-true
    (stdlib.math.f64-nan?
      (stdlib.math.f64-pow
        (stdlib.math.f64-from-bits (cast 0x4000000000000000 : u64))
        (stdlib.math.f64-from-bits (cast 0x7ff8000000000000 : u64))))
    "math-pow-f64-special: (f64-nan? (f64-pow (f64-from-bits (cast 0x400000000000000...")
  (test.assert-true
    (stdlib.math.f64-nan?
      (stdlib.math.f64-pow
        (stdlib.math.f64-from-bits (cast 0xfff8000000001234 : u64))
        (stdlib.math.f64-from-bits (cast 0x3fe0000000000000 : u64))))
    "math-pow-f64-special: (f64-nan? (f64-pow (f64-from-bits (cast 0xfff800000000123...")
  (test.assert-true
    (stdlib.math.f64-nan?
      (stdlib.math.f64-pow
        (stdlib.math.f64-from-bits (cast 0x3fe0000000000000 : u64))
        (stdlib.math.f64-from-bits (cast 0x7ff0000000000001 : u64))))
    "math-pow-f64-special: (f64-nan? (f64-pow (f64-from-bits (cast 0x3fe000000000000...")
  (test.assert-true
    (stdlib.math.f64-nan?
      (stdlib.math.f64-pow
        (stdlib.math.f64-from-bits (cast 0xc000000000000000 : u64))
        (stdlib.math.f64-from-bits (cast 0x3fe0000000000000 : u64))))
    "math-pow-f64-special: (f64-nan? (f64-pow (f64-from-bits (cast 0xc00000000000000...")
  (test.assert-true
    (stdlib.math.f64-nan?
      (stdlib.math.f64-pow
        (stdlib.math.f64-from-bits (cast 0xc020000000000000 : u64))
        (stdlib.math.f64-from-bits (cast 0x3ff8000000000000 : u64))))
    "math-pow-f64-special: (f64-nan? (f64-pow (f64-from-bits (cast 0xc02000000000000..."))

(test
  math-pow-f32-special
  (test.assert-true
    (stdlib.math.f32-nan?
      (stdlib.math.f32-pow
        (stdlib.math.f32-from-bits (cast 0x7fc00000 : u32))
        (stdlib.math.f32-from-bits (cast 0x40000000 : u32))))
    "math-pow-f32-special: (f32-nan? (f32-pow (f32-from-bits (cast 0x7fc00000 : u32)...")
  (test.assert-true
    (stdlib.math.f32-nan?
      (stdlib.math.f32-pow
        (stdlib.math.f32-from-bits (cast 0x40000000 : u32))
        (stdlib.math.f32-from-bits (cast 0x7fc00000 : u32))))
    "math-pow-f32-special: (f32-nan? (f32-pow (f32-from-bits (cast 0x40000000 : u32)...")
  (test.assert-true
    (stdlib.math.f32-nan?
      (stdlib.math.f32-pow
        (stdlib.math.f32-from-bits (cast 0xc0000000 : u32))
        (stdlib.math.f32-from-bits (cast 0x3f000000 : u32))))
    "math-pow-f32-special: (f32-nan? (f32-pow (f32-from-bits (cast 0xc0000000 : u32)..."))