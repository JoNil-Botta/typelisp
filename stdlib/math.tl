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
          (set! y (* y 8.9884656743115795e+307))
          (set! n (- n 1023))
          (if (> n 1023)
            (begin
              (set! y (* y 8.9884656743115795e+307))
              (set! n (- n 1023))
              (if (> n 1023)
                (set! n 1023)
                unit))
            unit))
        (if (< n -1022)
          (begin
            (set! y (* y 2.0041683600089728e-292))
            (set! n (+ n 969))
            (if (< n -1022)
              (begin
                (set! y (* y 2.0041683600089728e-292))
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
          (set! y (* y (cast 1.7014118346046923e+38 : f32)))
          (set! n (- n 127))
          (if (> n 127)
            (begin
              (set! y (* y (cast 1.7014118346046923e+38 : f32)))
              (set! n (- n 127))
              (if (> n 127)
                (set! n 127)
                unit))
            unit))
        (if (< n -126)
          (begin
            (set! y (* y (cast 1.9721522630525295e-31 : f32)))
            (set! n (+ n 102))
            (if (< n -126)
              (begin
                (set! y (* y (cast 1.9721522630525295e-31 : f32)))
                (set! n (+ n 102))
                (if (< n -126)
                  (set! n -126)
                  unit))
              unit))
          unit))
      (* y (stdlib.math.f32-from-bits (shl (cast (+ 127 n) : u32) 23))))))

;; The musl data tables below are written as `math-bits-table` rows. The macros
;; expand them into exactly the `cond` chain they replace, so each table stays
;; an in-code compare chain rather than a heap-allocated module-global array.
;: Internal: build one table entry from a `(row field ...)` row.
;:
;: An integer field is a raw `u64` word; any other field is a binary64 decimal
;: whose bits the private bitcast intrinsic folds to an integer constant,
;: exactly as a literal `(f64-to-bits x)` call lowers. Any other operand
;: shape is passed to `constructor` unchanged.
(defmacro (math-bits-row [constructor : comptime.Expr] [row : comptime.Expr]) : comptime.Expr
  (match row
    [(comptime.Expr.Call _ row-fields)
      (let
        [fields : comptime.ExprList (comptime.expr-list-empty)]
        [field-index : i64 (- (comptime.expr-list-length row-fields) 1)]
        (begin
          ;; Prepend back to front so the fields stay in source order.
          (while (>= field-index 0)
            (let
              [field : comptime.Expr
                (comptime.expr-list-nth row-fields field-index)]
              (begin
                (match field
                  [(comptime.Expr.Int _)
                    (set! fields (comptime.expr-list-cons field fields))]
                  [_
                    (set!
                      fields
                      (comptime.expr-list-cons
                        `(__tl_float_to_bits ,field)
                        fields))])
                (set! field-index (- field-index 1)))))
          `(,constructor ,@fields)))]
    [_ `(,constructor ,row)]))

;: Internal: expand constant table rows into an `index` lookup chain.
;:
;: Row `i` becomes `[(= index i) (constructor field ...)]` and the chain ends in
;: `[else fallback]`, the same `if` chain `cond` produces.
(defmacro (math-bits-table
  [index : comptime.Expr]
  [constructor : comptime.Expr]
  [fallback : comptime.Expr]
  [rows : comptime.Expr ...]) : comptime.Expr
  (let
    [out : comptime.Expr fallback]
    [row-index : i64 (- (comptime.expr-list-length rows) 1)]
    (begin
      ;; Build the chain from the last row outwards, as `cond` folds its arms.
      (while (>= row-index 0)
        (begin
          (set!
            out
            `(if (= ,index ,(comptime.expr-int row-index))
              (stdlib.math.math-bits-row
                ,constructor
                ,(comptime.expr-list-nth rows row-index))
              ,out))
          (set! row-index (- row-index 1))))
      out)))

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
  (math-bits-table
    index
    MathExpF64TableEntry
    (MathExpF64TableEntry 0 0)
    (row 0.0 0x3ff0000000000000)
    (row 9.447885451727066e-17 0x3feff63da9fb3335)
    (row -1.507066976926039e-17 0x3fefec9a3e778061)
    (row -5.679155082825012e-17 0x3fefe315e86e7f85)
    (row 4.9997448722726326e-17 0x3fefd9b0d3158574)
    (row -4.823683599994895e-17 0x3fefd06b29ddf6de)
    (row 7.357846871247418e-18 0x3fefc74518759bc8)
    (row 5.773230223741951e-17 0x3fefbe3ecac6f383)
    (row 8.189317638195515e-17 0x3fefb5586cf9890f)
    (row 5.326891139980878e-17 0x3fefac922b7247f7)
    (row 1.6665881442326747e-18 0x3fefa3ec32d3d1a2)
    (row -1.128113245461828e-17 0x3fef9b66affed31b)
    (row -7.402825309426177e-17 0x3fef9301d0125b51)
    (row -3.578659767309563e-18 0x3fef8abdc06c31cc)
    (row -6.170654745608695e-17 0x3fef829aaea92de0)
    (row 2.919139999949279e-17 0x3fef7a98c8a58e51)
    (row -2.7939114859515733e-17 0x3fef72b83c7d517b)
    (row -5.399285355184285e-17 0x3fef6af9388c8dea)
    (row 4.776959425256223e-17 0x3fef635beb6fcb75)
    (row -7.927701432338473e-17 0x3fef5be084045cd4)
    (row 9.341710609905046e-17 0x3fef54873168b9aa)
    (row -5.534520675707472e-17 0x3fef4d5022fcd91d)
    (row 4.585670326662351e-17 0x3fef463b88628cd6)
    (row 2.8582430411116143e-17 0x3fef3f49917ddc96)
    (row 7.826573258636076e-17 0x3fef387a6e756238)
    (row 4.053626906769216e-17 0x3fef31ce4fb2a63f)
    (row 2.823784425951061e-17 0x3fef2b4565e27cdd)
    (row -7.882802262487991e-17 0x3fef24dfe1f56381)
    (row 3.2904726646008416e-17 0x3fef1e9df51fdee1)
    (row -1.5792094703347882e-18 0x3fef187fd0dad990)
    (row 4.721368121170128e-17 0x3fef1285a6e4030b)
    (row 1.3045277096919659e-17 0x3fef0cafa93e2f56)
    (row 3.3484623336251524e-17 0x3fef06fe0a31b715)
    (row 3.8611199774925664e-17 0x3fef0170fc4cd831)
    (row 5.527550048505249e-17 0x3feefc08b26416ff)
    (row -3.927184172445234e-17 0x3feef6c55f929ff1)
    (row -6.346552106729483e-17 0x3feef1a7373aa9cb)
    (row -8.684417614865944e-17 0x3feeecae6d05d866)
    (row -1.5456342819397733e-17 0x3feee7db34e59ff7)
    (row -8.70763476495455e-17 0x3feee32dc313a8e5)
    (row 3.750854201303127e-17 0x3feedea64c123422)
    (row -6.616854503526488e-17 0x3feeda4504ac801c)
    (row -5.346099009198751e-18 0x3feed60a21f72e2a)
    (row -2.443726321015018e-17 0x3feed1f5d950a897)
    (row 2.1023049675215714e-18 0x3feece086061892d)
    (row 7.771067937501065e-17 0x3feeca41ed1d0057)
    (row 1.3357510088834541e-17 0x3feec6a2b5c13cd0)
    (row 6.938291696959204e-17 0x3feec32af0d7d3de)
    (row 1.9572585293112036e-17 0x3feebfdad5362a27)
    (row 6.632256961675804e-17 0x3feebcb299fddd0d)
    (row -5.478069123926778e-17 0x3feeb9b2769d2ca7)
    (row -4.140839310392624e-17 0x3feeb6daa2cf6642)
    (row -2.1571477251208752e-17 0x3feeb42b569d4f82)
    (row -3.8287766552120535e-17 0x3feeb1a4ca5d920f)
    (row 6.663804589232195e-17 0x3feeaf4736b527da)
    (row 2.3936187400285282e-17 0x3feead12d497c7fd)
    (row 5.68648095791174e-17 0x3feeab07dd485429)
    (row 1.1264523354521684e-18 0x3feea9268a5946b7)
    (row 7.007875046906994e-17 0x3feea76f15ad2148)
    (row -5.0119214278381254e-17 0x3feea5e1b976dc09)
    (row -4.8923067513522756e-17 0x3feea47eb03a5585)
    (row -3.5260089953269434e-17 0x3feea34634ccc320)
    (row -6.872303720902018e-17 0x3feea23882552225)
    (row 5.001446664133532e-18 0x3feea155d44ca973)
    (row -6.835808657661922e-17 0x3feea09e667f3bcd)
    (row -1.1307344092910212e-17 0x3feea012750bdabf)
    (row -8.416011634717156e-18 0x3fee9fb23c651a2f)
    (row -2.9247977035436566e-17 0x3fee9f7df9519484)
    (row -2.092304381843353e-17 0x3fee9f75e8ec5f74)
    (row -3.9778645875427124e-17 0x3fee9f9a48a58174)
    (row -3.833464968654295e-17 0x3fee9feb564267c9)
    (row 5.763611164480894e-17 0x3feea0694fde5d3f)
    (row -2.3591094770850053e-17 0x3feea11473eb0187)
    (row 7.260074661098575e-17 0x3feea1ed0130c132)
    (row 9.50689710108796e-18 0x3feea2f336cf4e62)
    (row -4.272956133839906e-17 0x3feea427543e1a12)
    (row -6.735219232374683e-17 0x3feea589994cce13)
    (row -2.8396044410430936e-17 0x3feea71a4623c7ad)
    (row -7.226635472101257e-17 0x3feea8d99b4492ed)
    (row 5.786121003395918e-17 0x3feeaac7d98a6699)
    (row 5.1548301170786783e-17 0x3feeace5422aa0db)
    (row -9.416257568878152e-18 0x3feeaf3216b5448c)
    (row 2.4253985766689806e-17 0x3feeb1ae99157736)
    (row -6.604314051707707e-17 0x3feeb45b0b91ffc6)
    (row -6.432131775424189e-18 0x3feeb737b0cdc5e5)
    (row -1.2204007601863921e-17 0x3feeba44cbc8520f)
    (row -6.336161863401293e-17 0x3feebd829fde4e50)
    (row -3.7800879246373815e-17 0x3feec0f170ca07ba)
    (row 1.5341410053603723e-17 0x3feec49182a3f090)
    (row 1.2932855580427452e-17 0x3feec86319e32323)
    (row -4.123367330661149e-17 0x3feecc667b5de565)
    (row 4.703083974463456e-17 0x3feed09bec4a2d33)
    (row -6.152602891550265e-17 0x3feed503b23e255d)
    (row 5.827849326195279e-17 0x3feed99e1330b358)
    (row 3.540948262646183e-17 0x3feede6b5579fdbf)
    (row -3.2741571320938764e-17 0x3feee36bbfd3f37a)
    (row 4.875160526227062e-17 0x3feee89f995ad3ad)
    (row -5.718569790077838e-17 0x3feeee07298db666)
    (row -4.719539664590972e-18 0x3feef3a2b84f15fb)
    (row -5.773451958805706e-17 0x3feef9728de5593a)
    (row -1.0772487078934056e-17 0x3feeff76f2fb5e47)
    (row -6.221808618533911e-17 0x3fef05b030a1064a)
    (row 1.821405440362259e-17 0x3fef0c1e904bc1d2)
    (row -6.155536546227639e-17 0x3fef12c25bd71e09)
    (row 1.685487290628973e-17 0x3fef199bdd85529c)
    (row 5.3581249177694816e-17 0x3fef20ab5fffd07a)
    (row 3.621615935336894e-17 0x3fef27f12e57d14b)
    (row 8.588379527574144e-18 0x3fef2f6d9406e7b5)
    (row 1.01562190116415e-17 0x3fef3720dcef9069)
    (row -2.869134889187244e-17 0x3fef3f0b555dc3fa)
    (row -5.495118966122005e-17 0x3fef472d4a07897c)
    (row -5.56965572431627e-17 0x3fef4f87080d89f2)
    (row 1.790126907604513e-17 0x3fef5818dcfba487)
    (row -3.2211766346200164e-17 0x3fef60e316c98398)
    (row 5.265370768556274e-17 0x3fef69e603db3285)
    (row 3.5089866402403033e-17 0x3fef7321f301b460)
    (row -3.266924100901318e-17 0x3fef7c97337b9b5f)
    (row -4.3657593008079375e-17 0x3fef864614f5a129)
    (row 1.7963932659833022e-17 0x3fef902ee78b3ff6)
    (row 3.4300925275214166e-17 0x3fef9a51fbc74c83)
    (row -5.545065618639427e-17 0x3fefa4afa2a490da)
    (row -5.149009745457733e-17 0x3fefaf482d8e67f1)
    (row 5.336805878514151e-17 0x3fefba1bee615a27)
    (row 3.498978661192973e-17 0x3fefc52b376bba97)
    (row 4.5784915277060095e-17 0x3fefd0765b6e4540)
    (row -5.241934575393899e-17 0x3fefdbfdad9cbe14)
    (row 2.0414278897578303e-17 0x3fefe7c1819e90d8)
    (row 4.124842848606488e-18 0x3feff3c22b8f71f1)))

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
      (begin
        (if (< y 1.0)
          (let
            [lo : f64 (+ (- scale y) (* scale tmp))]
            [hi : f64 (+ 1.0 y)]
            (begin
              (set! lo (+ (+ (- 1.0 hi) y) lo))
              (set! y (- (+ hi lo) 1.0))))
          unit)
        (* 2.2250738585072014e-308 y)))))

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
          [index : i64 (cast (% k-bits (cast 128 : u64)) : i64)]
          [entry : MathExpF64TableEntry (math-exp-f64-table-entry index)]
          [scale-bits : u64 (+ entry.scale-bits (shl k-bits 45))]
          [tail : f64 (stdlib.math.f64-from-bits entry.tail-bits)]
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
    [entry : MathExpF64TableEntry
      (math-exp-f64-table-entry (* (cast (% k-bits (cast 32 : u64)) : i64) 4))]
    [scale-bits : u64 (+ entry.scale-bits (shl k-bits 47))]
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
  (math-bits-table
    index
    MathLogF64TableEntry
    (MathLogF64TableEntry 0 0 0 0)
    (row
      1.4504249240398293
      -0.37185656456335892
      0.68945312744263043
      2.6029065281053499e-17)
    (row
      1.4422535083272761
      -0.36620682668944937
      0.69335938115331663
      5.1607448519931415e-17)
    (row
      1.4341736174350004
      -0.36058880697919449
      0.69726565029726739
      5.2906724148878689e-17)
    (row
      1.4261838163299949
      -0.35500221714198688
      0.70117188860921476
      7.8010306348060135e-18)
    (row
      1.4182825527052965
      -0.34944666968829097
      0.70507812289769389
      -2.471355337688684e-17)
    (row
      1.4104682921759335
      -0.34392177136032842
      0.7089843887644558
      -4.6413389636862956e-17)
    (row
      1.4027396147468003
      -0.33842719212611883
      0.71289068155425528
      3.3387408065940366e-17)
    (row
      1.3950954438932313
      -0.33296283149434203
      0.71679683592783028
      -2.6454587338050098e-17)
    (row
      1.3875338232485754
      -0.32752794345742586
      0.7207031520563163
      2.4284096334522285e-17)
    (row
      1.3800539211058593
      -0.32212257167088865
      0.72460936830546729
      4.8578243503198198e-17)
    (row
      1.3726542695419708
      -0.3167462884799761
      0.72851556447180355
      -1.3014776598894487e-17)
    (row
      1.3653332798446802
      -0.3113985598928366
      0.73242190369355065
      -1.0402317671225898e-17)
    (row
      1.358090204587874
      -0.30607945151655258
      0.73632811474658999
      3.0782914274674313e-17)
    (row
      1.3509234892132138
      -0.30078842466764399
      0.74023437151307969
      -1.4304998976623033e-17)
    (row
      1.3438320840699889
      -0.29552529684769979
      0.74414059007384026
      -2.8625955785571303e-17)
    (row
      1.3368146974742003
      -0.29028969275850613
      0.74804683243640002
      5.1609093535635645e-17)
    (row
      1.3298701146777361
      -0.28508127932775551
      0.75195313359028848
      4.423423949536319e-17)
    (row
      1.3229973391611061
      -0.27989987391470095
      0.75585941891167063
      -4.6830167620995081e-17)
    (row
      1.316195352741367
      -0.27474526621870154
      0.75976563655023055
      4.4667420075147718e-17)
    (row
      1.3094628125672239
      -0.26961698637012432
      0.76367193508877373
      -4.8134498775190266e-17)
    (row
      1.3027990455471041
      -0.26451506180308115
      0.76757808767050095
      -4.3371015350542286e-17)
    (row
      1.2962024229438942
      -0.25943877627673828
      0.77148443969795355
      -2.5156444722517071e-17)
    (row
      1.2896726275815547
      -0.25438840909816918
      0.77539057479667517
      -4.163636184961329e-17)
    (row
      1.2832080305745537
      -0.24936321635129843
      0.77929686860847658
      3.3837161384165165e-17)
    (row
      1.276807885983376
      -0.24436312405975968
      0.78320318270106604
      4.3792065650567583e-17)
    (row
      1.2704714060687552
      -0.23938801747897287
      0.78710941090309128
      2.7322930976146396e-17)
    (row
      1.2641976054949482
      -0.23443761696705678
      0.79101557830311531
      -5.4636612253640457e-17)
    (row
      1.2579853575148821
      -0.22951151871518505
      0.79492181210715718
      -1.4320502634189868e-17)
    (row
      1.2518337750655457
      -0.2246094963439873
      0.79882810315422292
      -4.0766731402809024e-17)
    (row
      1.2457421919097305
      -0.21973149037705753
      0.80273431091467962
      -4.0338264352540086e-17)
    (row
      1.2397094966625508
      -0.2148770752847895
      0.80664059014803224
      1.7241428071650815e-18)
    (row
      1.2337348463589233
      -0.21004602910363701
      0.81054693636259334
      -4.5534218930924523e-17)
    (row
      1.2278176973028803
      -0.20523836373934046
      0.8144531571720115
      1.8212169205891421e-17)
    (row
      1.2219570190618474
      -0.20045368751368642
      0.81835938940613961
      4.9864288025894273e-17)
    (row
      1.2161519732977757
      -0.1956917537758045
      0.82226565590182965
      4.3359904167266887e-17)
    (row
      1.2104018095009725
      -0.19095237845203883
      0.82617193080063434
      -5.4220014716611272e-17)
    (row
      1.204705805718973
      -0.18623539250290833
      0.83007817780308302
      -5.3336037289290352e-17)
    (row
      1.1990631185441964
      -0.18154051731551135
      0.83398445380766739
      -1.1270648442682386e-17)
    (row
      1.1934733004462308
      -0.17686779574319189
      0.83789054989844136
      -3.1651267348003982e-17)
    (row
      1.1879350812847385
      -0.17221657406412305
      0.84179684206186689
      1.1286283062565865e-17)
    (row
      1.1824481322833125
      -0.16758697765942543
      0.84570305681738078
      5.643595964448442e-18)
    (row
      1.1770114976921955
      -0.16297859687290384
      0.84960937251737334
      -2.1687834632368187e-17)
    (row
      1.1716248121809465
      -0.15839151377804228
      0.85351555344626773
      -2.2548234217914977e-17)
    (row
      1.1662869231674715
      -0.15382513241456763
      0.85742194320771459
      4.6832605563531392e-17)
    (row
      1.1609977486762766
      -0.14927976358922024
      0.86132811294437062
      2.5148296884122795e-17)
    (row
      1.1557563220795803
      -0.14475495398119165
      0.86523428935320534
      -8.6721875709494672e-18)
    (row
      1.1505619105480347
      -0.14025044090817573
      0.86914053979388284
      -1.2576268285559751e-17)
    (row
      1.1454138888505974
      -0.13576604666855019
      0.87304686081943916
      -2.9930851265147998e-17)
    (row
      1.1403118773746559
      -0.1313018016355727
      0.87695306857831168
      4.8148015076816437e-17)
    (row
      1.1352550225747513
      -0.12685731518763532
      0.88085934888181006
      -9.1054953361102193e-18)
    (row
      1.1302429094831266
      -0.12243257376712791
      0.88476555934096668
      -3.5124146516207661e-17)
    (row
      1.1252747693068048
      -0.11802724521862729
      0.88867184022620804
      3.5552618153740227e-17)
    (row
      1.1203501571039876
      -0.11364127671663482
      0.89257808700176133
      1.692380503540994e-17)
    (row
      1.1154683327680124
      -0.10927434611278386
      0.89648443673745537
      -1.0837881791715702e-17)
    (row
      1.1106291463292157
      -0.10492665324943573
      0.90039056088626834
      5.2900545724138363e-17)
    (row
      1.1058315813301596
      -0.10059761422644442
      0.90429683586820775
      5.3330721088784517e-17)
    (row
      1.1010752177696026
      -0.096287173090559008
      0.90820316710574411
      1.8640040753232978e-17)
    (row
      1.0963597137952512
      -0.091995340695575578
      0.91210939933054969
      4.4679728320540751e-17)
    (row
      1.0916844827550398
      -0.087721900366886985
      0.91601558490264567
      -5.2162134195850327e-18)
    (row
      1.0870487291277784
      -0.083466436138678546
      0.91992196228624989
      -2.7324731032846873e-17)
    (row
      1.082452357388312
      -0.079229168275446682
      0.9238281880717143
      -1.7769263393434193e-17)
    (row
      1.0778948225025884
      -0.075009900475038194
      0.92773430127279288
      4.9433630808174411e-17)
    (row
      1.0733751731601076
      -0.070808051333528965
      0.93164070215627881
      4.164434042024055e-17)
    (row
      1.068893585073351
      -0.06662408085151128
      0.93554682520746602
      1.3011820859795741e-17)
    (row
      1.0644491706655506
      -0.062457454719151428
      0.93945303125629431
      -2.7332907838481398e-17)
    (row
      1.0600414846328305
      -0.058308043804231602
      0.94335930668446688
      2.3421331708032919e-17)
    (row
      1.0556701316181605
      -0.05417576112313327
      0.94726559940383293
      1.6478717480487438e-17)
    (row
      1.0513347505569259
      -0.050060547896805474
      0.9511718313032721
      -5.1960829013149901e-18)
    (row
      1.0470347288442157
      -0.045962101199052086
      0.95507815782181782
      -3.5565573220578997e-17)
    (row
      1.0427699229652954
      -0.041880560088657148
      0.95898431473390433
      2.0816772146458738e-17)
    (row
      1.0385395013738175
      -0.037815400561839851
      0.96289067356336855
      -3.4719628261468409e-18)
    (row
      1.0343434189403451
      -0.033766847579158821
      0.9667968893972092
      -3.6864683447264197e-17)
    (row
      1.0301811073173315
      -0.029734619131772888
      0.97070310540257787
      -3.4674108076868834e-18)
    (row
      1.026052043621297
      -0.025718470239212365
      0.97460943254949306
      4.5981526247743919e-17)
    (row
      1.0219561082336197
      -0.021718543925430822
      0.97851560545827221
      4.5531457523925683e-17)
    (row
      1.0178926505784922
      -0.017734461269810708
      0.98242186878122817
      -7.8112591694189783e-18)
    (row
      1.0138614436244586
      -0.013766252464051831
      0.98632806907529169
      2.0375615178047467e-17)
    (row
      1.0098620186501341
      -0.0098137063225749444
      0.99023429095460336
      -1.344597043422914e-17)
    (row
      1.0058938559734134
      -0.005876555150052809
      0.99414067802640083
      1.5185372369505401e-17)
    (row
      1.0019569623501401
      -0.0019550499938532084
      0.99804685987155584
      -1.301926039598001e-17)
    (row
      0.99610899230885086
      0.0038985973556009412
      1.0039062067717412
      -4.5961206417449733e-17)
    (row
      0.98841703381852009
      0.011650571286395461
      1.0117187035281372
      -8.1524050026653492e-17)
    (row
      0.98084291910052968
      0.019342955478919066
      1.0195312424919558
      8.2399270147578115e-17)
    (row
      0.97338401699874455
      0.026976601484648199
      1.0273437641634193
      3.1228510053270453e-17)
    (row
      0.96603775688765559
      0.034552359728422744
      1.0351562274561221
      -1.3010212611128995e-17)
    (row
      0.95880149453073693
      0.042071217671832528
      1.0429687539123276
      -5.9841166886334577e-17)
    (row
      0.95167285690731107
      0.049533940950141186
      1.0507812561238108
      2.8609238548223351e-17)
    (row
      0.9446494635965822
      0.056941358295944156
      1.0585937308350133
      -1.9962944508904598e-17)
    (row
      0.93772889930262227
      0.064294391683461072
      1.0664062936992642
      5.2914691303090992e-17)
    (row
      0.93090910737906807
      0.071593635494650698
      1.0742187309945372
      1.0321575006732523e-16)
    (row
      0.92418768161272202
      0.078840109337761533
      1.0820313015371339
      9.0211943734191189e-17)
    (row
      0.91756267655991919
      0.086034389059705063
      1.0898438063644336
      5.2027989923579528e-17)
    (row
      0.91103204036240337
      0.093177211800139048
      1.0976562356711468
      5.8983184825007853e-17)
    (row
      0.90459358397620238
      0.10026951462748457
      1.1054688179463226
      8.8463776906532518e-17)
    (row
      0.89824563759228249
      0.10731170956330516
      1.113281220803328
      -9.5294559652125745e-18)
    (row
      0.89198609667825013
      0.11430473320717738
      1.1210937073167315
      6.7650807093777866e-17)
    (row
      0.88581311211851288
      0.12124928503033061
      1.1289062967338532
      1.0929327370933015e-16)
    (row
      0.87972507576067605
      0.12814583422959913
      1.1367187631150848
      6.9385705512305156e-17)
    (row
      0.87372013726346853
      0.13499516368517561
      1.1445312490244826
      1.908841015045148e-17)
    (row
      0.86779664057822725
      0.1417978768189414
      1.1523437096203593
      2.7744504138979832e-17)
    (row
      0.86195280500607385
      0.14855476039031146
      1.1601563266482477
      -1.5621964097491672e-17)
    (row
      0.85618723544206921
      0.15526619376589679
      1.1679688257483505
      -6.4191661495975e-17)
    (row
      0.85049839278168926
      0.16193275688146969
      1.1757811754697645
      -4.3364651650592681e-17)
    (row
      0.84488445727903039
      0.16855539792220497
      1.1835937936656129
      -3.8159292551356396e-17)
    (row
      0.83934427415759649
      0.1751343179947753
      1.1914062331617676
      -2.94933042768015e-17)
    (row
      0.83387622493494384
      0.1816702989864325
      1.1992187450577771
      -6.2441429163513478e-17)
    (row
      0.82847893205577783
      0.18816387146023317
      1.2070312971249755
      7.4586446226274127e-17)
    (row
      0.82315108000658321
      0.1946155228479256
      1.2148438169965134
      2.7760519266147807e-17)
    (row
      0.81789139037787073
      0.20102572579389744
      1.2226562252208011
      -7.0251069210796655e-17)
    (row
      0.81269840072453736
      0.20739520907955011
      1.2304687681290862
      3.7292622364618835e-17)
    (row
      0.80757100294602269
      0.21372429840596396
      1.2382812116234925
      2.2558949940652082e-17)
    (row
      0.80250788811604146
      0.22001359459818559
      1.2460936706149877
      8.4993689444006646e-17)
    (row
      0.79750773793643315
      0.22626374162859975
      1.2539063289686938
      1.039515474644361e-17)
    (row
      0.79256960496637296
      0.23247494747693054
      1.2617188367227732
      3.2972622232754989e-17)
    (row
      0.78769236412541144
      0.23864766620658884
      1.2695311590462317
      4.5098832535941547e-17)
    (row
      0.78287467249409981
      0.24478265647405806
      1.2773436606579409
      -7.546987371769545e-17)
    (row
      0.77811553887908114
      0.25088025827324145
      1.2851561882963496
      9.4542955988181837e-17)
    (row
      0.77341395578697769
      0.25694085525105947
      1.2929686521915196
      -7.2854560911974897e-17)
    (row
      0.76876871799149327
      0.26296511155101143
      1.3007813359167737
      -8.9343576514628023e-17)
    (row
      0.76417906980418537
      0.26895313271893428
      1.3085938093753886
      8.1525705945810205e-17)
    (row
      0.75964387636923991
      0.27490553924610595
      1.3164063202609564
      6.9463414607658815e-18)
    (row
      0.75516219510786675
      0.28082272484789428
      1.3242188320313901
      -7.8927313807216758e-17)
    (row
      0.7507331780216866
      0.28670497926725602
      1.3320311786874468
      -4.3384657500713545e-17)
    (row
      0.74635571963617509
      0.29255295645509705
      1.3398436880573092
      9.6275779545987923e-17)
    (row
      0.74202893648696533
      0.29836703861428759
      1.3476563390295309
      4.2492400590204517e-17)
    (row
      0.73775215370658764
      0.30414734587282055
      1.3554687641043626
      -1.0843419551446047e-16)
    (row
      0.73352429660026075
      0.30989455774829366
      1.3632813590971713
      -8.5017278247202501e-17)
    (row
      0.72934477745784099
      0.31560871301871884
      1.3710936595522603
      -7.1106272061629222e-17)))

;: Internal binary32 logarithm reduction constants, evaluated as binary64.
(defstruct MathLogF32TableEntry
  (invc-bits u64)
  (logc-bits u64))

;: Return the exact musl binary32 logarithm constants for interval index.
(define (math-log-f32-table-entry [index : i64]) : MathLogF32TableEntry
  (math-bits-table
    index
    MathLogF32TableEntry
    (MathLogF32TableEntry 0 0)
    (row 1.3989071621465281 -0.33569133332882284)
    (row 1.3403141896637998 -0.29290405637740741)
    (row 1.286432210124115 -0.25187265809373688)
    (row 1.2367150214269895 -0.21245868807117255)
    (row 1.1906977166711752 -0.17453945183745634)
    (row 1.1479821020556429 -0.1380057072319758)
    (row 1.1082251448272158 -0.10275976698545139)
    (row 1.0711297413057381 -0.068713924470205245)
    (row 1.0364372789772831 -0.035789138739822798)
    (row 1.0 0.0)
    (row 0.9492859795739057 0.052045177429294959)
    (row 0.89510494286090037 0.11081431298787942)
    (row 0.84768216203511026 0.16524952236951429)
    (row 0.80503148516920009 0.21687389031699977)
    (row 0.7664671008843108 0.26596350281213971)
    (row 0.73142860331632797 0.31275566640735569)))

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
    (begin
      (set! lo (+ lo (* (* -0.5 rlo) (+ rhi r))))
      (set! y (+ y lo))
      (+ y hi))))

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
    [entry : MathLogF64TableEntry (math-log-f64-table-entry index)]
    [invc : f64 (stdlib.math.f64-from-bits entry.invc-bits)]
    [logc : f64 (stdlib.math.f64-from-bits entry.logc-bits)]
    [chi : f64 (stdlib.math.f64-from-bits entry.chi-bits)]
    [clo : f64 (stdlib.math.f64-from-bits entry.clo-bits)]
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
    [entry : MathLogF32TableEntry (math-log-f32-table-entry index)]
    [invc : f64 (stdlib.math.f64-from-bits entry.invc-bits)]
    [logc : f64 (stdlib.math.f64-from-bits entry.logc-bits)]
    [z : f64 (cast (stdlib.math.f32-from-bits reduced-bits) : f64)]
    [r : f64 (- (* z invc) 1.0)]
    [y0 : f64 (+ logc (* (cast k : f64) 0.69314718055994529))]
    [r2 : f64 (* r r)]
    [y : f64 (+ (* 0.33345676574406602 r) -0.49999974858021029)]
    (begin
      (set! y (+ (* -0.25089342214237154 r2) y))
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
;: Internal binary64 pow logarithm constants for one table interval.
(defstruct MathPowLogF64TableEntry
  (invc-bits u64)
  (logc-bits u64)
  (logctail-bits u64))

;: Return the exact musl pow_data.c constants for interval index.
(define (math-pow-f64-table-entry [index : i64]) : MathPowLogF64TableEntry
  (math-bits-table
    index
    MathPowLogF64TableEntry
    (MathPowLogF64TableEntry 0 0 0)
    (row 1.4140625 -0.3464667673462145 5.929407345889625e-15)
    (row 1.40625 -0.34092658697056777 -2.544157440035963e-14)
    (row 1.3984375 -0.3353555419211034 -3.443525940775045e-14)
    (row 1.390625 -0.3297532863724655 -2.500123826022799e-15)
    (row 1.3828125 -0.32411946865420305 -8.929337133850617e-15)
    (row 1.375 -0.31845373111855224 1.7625431312172662e-14)
    (row 1.3671875 -0.31275571000389846 1.5688303180062087e-15)
    (row 1.359375 -0.3070250352949415 2.9655274673691784e-14)
    (row 1.3515625 -0.3012613305781997 3.7923164802093147e-14)
    (row 1.34375 -0.2954642128938758 3.993416384387844e-14)
    (row 1.3359375 -0.28963329258306203 1.9352855826489123e-14)
    (row 1.3359375 -0.28963329258306203 1.9352855826489123e-14)
    (row 1.328125 -0.28376817313062475 -1.9852665484979036e-14)
    (row 1.3203125 -0.27786845100342816 -2.814323765595281e-14)
    (row 1.3125 -0.2719337154836694 2.7643769993528702e-14)
    (row 1.3046875 -0.2659635484970977 -4.025092402293806e-14)
    (row 1.296875 -0.25995752443691345 -1.2621729398885316e-14)
    (row 1.2890625 -0.25391520998095984 -3.600176732637335e-15)
    (row 1.2890625 -0.25391520998095984 -3.600176732637335e-15)
    (row 1.28125 -0.2478361639045943 1.3029797173308663e-14)
    (row 1.2734375 -0.2417199368871934 4.8230289429940886e-14)
    (row 1.265625 -0.23556607131274632 -2.0592242769647135e-14)
    (row 1.2578125 -0.22937410106487732 3.149265065191484e-14)
    (row 1.25 -0.22314355131425145 4.169796584527195e-14)
    (row 1.25 -0.22314355131425145 4.169796584527195e-14)
    (row 1.2421875 -0.21687393830063684 2.2477465222466186e-14)
    (row 1.234375 -0.21056476910735 3.6507188831790577e-16)
    (row 1.2265625 -0.2042155414286526 -3.827767260205414e-14)
    (row 1.2265625 -0.2042155414286526 -3.827767260205414e-14)
    (row 1.21875 -0.19782574332987224 -4.7641388950792196e-14)
    (row 1.2109375 -0.19139485299967873 4.9278276214647115e-14)
    (row 1.203125 -0.18492233849406148 4.9485167661250996e-14)
    (row 1.203125 -0.18492233849406148 4.9485167661250996e-14)
    (row 1.1953125 -0.1784076574728033 -1.5003333854266542e-14)
    (row 1.1875 -0.17185025692663203 -2.7194441649495324e-14)
    (row 1.1875 -0.17185025692663203 -2.7194441649495324e-14)
    (row 1.1796875 -0.1652495728952772 -2.99659267292569e-14)
    (row 1.171875 -0.15860503017665906 2.0472357800461955e-14)
    (row 1.171875 -0.15860503017665906 2.0472357800461955e-14)
    (row 1.1640625 -0.15191604202584585 3.879296723063646e-15)
    (row 1.15625 -0.1451820098444614 -3.6506824353335045e-14)
    (row 1.1484375 -0.13840232285906495 -5.4183331379008994e-14)
    (row 1.1484375 -0.13840232285906495 -5.4183331379008994e-14)
    (row 1.140625 -0.131576357788731 1.1729485484531301e-14)
    (row 1.140625 -0.131576357788731 1.1729485484531301e-14)
    (row 1.1328125 -0.12470347850091912 -3.811763084710266e-14)
    (row 1.125 -0.11778303565643 4.654729747598445e-14)
    (row 1.125 -0.11778303565643 4.654729747598445e-14)
    (row 1.1171875 -0.11081436634026431 -2.5799991283069902e-14)
    (row 1.109375 -0.10379679368168127 3.7700471749674615e-14)
    (row 1.109375 -0.10379679368168127 3.7700471749674615e-14)
    (row 1.1015625 -0.09672962645856842 1.7306161136093256e-14)
    (row 1.1015625 -0.09672962645856842 1.7306161136093256e-14)
    (row 1.09375 -0.089612158689647 -4.012913552726574e-14)
    (row 1.0859375 -0.08244366921110213 2.7541708360737882e-14)
    (row 1.0859375 -0.08244366921110213 2.7541708360737882e-14)
    (row 1.078125 -0.07522342123763792 5.0396178134370583e-14)
    (row 1.078125 -0.07522342123763792 5.0396178134370583e-14)
    (row 1.0703125 -0.06795066190852594 1.8195060030168815e-14)
    (row 1.0625 -0.06062462181648698 5.213620639136504e-14)
    (row 1.0625 -0.06062462181648698 5.213620639136504e-14)
    (row 1.0546875 -0.053244514518837605 2.532168943117445e-14)
    (row 1.0546875 -0.053244514518837605 2.532168943117445e-14)
    (row 1.046875 -0.045809536031242715 -5.148849572685811e-14)
    (row 1.046875 -0.045809536031242715 -5.148849572685811e-14)
    (row 1.0390625 -0.038318864302141264 4.6652946995830086e-15)
    (row 1.0390625 -0.038318864302141264 4.6652946995830086e-15)
    (row 1.03125 -0.03077165866670839 -4.529814257790929e-14)
    (row 1.03125 -0.03077165866670839 -4.529814257790929e-14)
    (row 1.0234375 -0.023167059281490765 -4.361324067851568e-14)
    (row 1.015625 -0.015504186535963527 -1.7274567499706107e-15)
    (row 1.015625 -0.015504186535963527 -1.7274567499706107e-15)
    (row 1.0078125 -0.0077821404420319595 -2.298941004620351e-14)
    (row 1.0078125 -0.0077821404420319595 -2.298941004620351e-14)
    (row 1.0 0.0 0.0)
    (row 1.0 0.0 0.0)
    (row 0.9921875 0.007843177461040796 -1.4902732911301337e-14)
    (row 0.984375 0.01574835696817445 -3.527980389655325e-14)
    (row 0.9765625 0.023716526617363343 -4.730054772033249e-14)
    (row 0.96875 0.03174869831457272 7.580310369375161e-15)
    (row 0.9609375 0.039845908547249564 -4.9893776716773285e-14)
    (row 0.953125 0.048009219186383234 -2.262629393030674e-14)
    (row 0.9453125 0.056239718322899535 -2.345674491018699e-14)
    (row 0.94140625 0.06038051098892083 -1.3352588834854848e-14)
    (row 0.93359375 0.06871389254808946 -3.765296820388875e-14)
    (row 0.92578125 0.07711730334438016 5.1128335719851986e-14)
    (row 0.91796875 0.08559193033545398 -5.046674438470119e-14)
    (row 0.9140625 0.08985632912185793 3.1218748807418837e-15)
    (row 0.90625 0.09844007281321865 3.3871241029241416e-14)
    (row 0.8984375 0.10709813555638448 -1.7376727386423858e-14)
    (row 0.89453125 0.11145544092528326 3.957125899799804e-14)
    (row 0.88671875 0.12022742699821265 -5.2849453521890294e-14)
    (row 0.8828125 0.12464244520731427 -3.767012502308738e-14)
    (row 0.875 0.13353139262449076 3.1859736349078334e-14)
    (row 0.87109375 0.13800567301939282 5.0900642926060466e-14)
    (row 0.86328125 0.14701474296180095 8.710783796122478e-15)
    (row 0.859375 0.15154989812720032 6.157896229122976e-16)
    (row 0.8515625 0.16068238169043525 3.821577743916796e-14)
    (row 0.84765625 0.16528009093906348 3.9440046718453496e-14)
    (row 0.83984375 0.17453941635187675 2.2924522154618074e-14)
    (row 0.8359375 0.17920142945774842 -3.742530094732263e-14)
    (row 0.83203125 0.18388527877016259 -2.5223102140407338e-14)
    (row 0.82421875 0.1933193110035063 -1.0320443688698849e-14)
    (row 0.8203125 0.19806991376208316 1.0634128304268335e-14)
    (row 0.8125 0.20763936477828793 -4.3425422595242564e-14)
    (row 0.80859375 0.21245865121420593 -1.2527395755711364e-14)
    (row 0.8046875 0.21730127569003344 -5.204008743405884e-14)
    (row 0.80078125 0.22216746534115828 -3.979844515951702e-15)
    (row 0.79296875 0.2319714654378231 -4.7955860343296286e-14)
    (row 0.7890625 0.2369097470783572 5.015686013791602e-16)
    (row 0.78515625 0.24187253642048745 -7.252318953240293e-16)
    (row 0.78125 0.2468600779315011 2.4688324156011588e-14)
    (row 0.7734375 0.2569104137850218 5.465121253624792e-15)
    (row 0.76953125 0.26197371574153294 4.102651071698446e-14)
    (row 0.765625 0.2670627852490952 -4.996736502345936e-14)
    (row 0.76171875 0.27217788591576664 4.903580708156347e-14)
    (row 0.7578125 0.27731928541618345 5.089628039500759e-14)
    (row 0.75390625 0.28248725557466514 1.1782016386565151e-14)
    (row 0.74609375 0.29290401643288533 4.727452940514406e-14)
    (row 0.7421875 0.29815337231912054 -4.4204083338755686e-14)
    (row 0.73828125 0.3034304294199046 1.548345993498083e-14)
    (row 0.734375 0.30873548164959175 2.1522127491642888e-14)
    (row 0.73046875 0.3140688276249648 1.1054030169005386e-14)
    (row 0.7265625 0.31943077076641657 -5.534326352070679e-14)
    (row 0.72265625 0.3248216194012912 -5.351646604259541e-14)
    (row 0.71875 0.33024168687052224 5.4612144489920215e-14)
    (row 0.71484375 0.3356912916381134 2.8136969901227338e-14)
    (row 0.7109375 0.3411707574027787 -1.156568624616423e-14)))

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
    [index : i64 (cast (% (shr tmp 45) (cast 128 : u64)) : i64)]
    [k : i64 (shr (cast tmp : i64) 52)]
    [iz : u64 (- ix (bit-and tmp (cast 0xfff0000000000000 : u64)))]
    [z : f64 (stdlib.math.f64-from-bits iz)]
    [kd : f64 (cast k : f64)]
    [entry : MathPowLogF64TableEntry (math-pow-f64-table-entry index)]
    [invc : f64 (stdlib.math.f64-from-bits entry.invc-bits)]
    [logc : f64 (stdlib.math.f64-from-bits entry.logc-bits)]
    [logctail : f64 (stdlib.math.f64-from-bits entry.logctail-bits)]
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
      (begin
        (if (and (< y 1.0) (> y -1.0))
          (let
            [one : f64
              (if (< y 0.0)
                -1.0
                1.0)]
            [lo : f64 (+ (- scale y) (* scale tmp))]
            [hi : f64 (+ one y)]
            (begin
              (set! lo (+ (+ (- one hi) y) lo))
              (set! y (- (+ hi lo) one))
              (if (= y 0.0)
                (set!
                  y
                  (stdlib.math.f64-from-bits
                    (bit-and adjusted-bits (cast 0x8000000000000000 : u64))))
                unit)))
          unit)
        (* 2.2250738585072014e-308 y)))))

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
    [entry : MathExpF64TableEntry
      (math-exp-f64-table-entry (cast (% k-bits (cast 128 : u64)) : i64))]
    [top : u64 (shl (+ k-bits sign-bias) 45)]
    [tail : f64 (stdlib.math.f64-from-bits entry.tail-bits)]
    [sbits : u64 (+ entry.scale-bits top)]
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
;: musl pow.c `exp_inline`, reusing the shared `__exp_data` table accessor.
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
            (begin
              (if (and
                (!= (shr ix 63) (cast 0 : u64))
                (= (math-pow-f64-checkint iy) 1))
                (set! x2 (* x2 -1.0))
                unit)
              (if (!= (shr iy 63) (cast 0 : u64))
                (/ 1.0 x2)
                x2)))]
        [else
          (begin
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
                  (if (= topx (cast 0 : u64))
                    (begin
                      (set!
                        ix
                        (bit-and
                          (stdlib.math.f64-to-bits (* x 4503599627370496.0))
                          (cast 0x7fffffffffffffff : u64)))
                      (set! ix (- ix (shl (cast 52 : u64) 52))))
                    unit)
                  (math-pow-f64-main ix y iy sign-bias)))))])
      (math-pow-f64-main ix y iy sign-bias))))

;: Internal binary32 pow log2 constants for one table interval. The upstream
;: powf_data.c entries are doubles, so the fields stay in the `u64` ABI.
(defstruct MathPowLogF32TableEntry
  (invc-bits u64)
  (logc-bits u64))

;: Return the exact musl powf_data.c constants for interval index.
(define (math-powf-table-entry [index : i64]) : MathPowLogF32TableEntry
  (math-bits-table
    index
    MathPowLogF32TableEntry
    (MathPowLogF32TableEntry 0 0)
    (row 1.398907162146528 -0.48430022186289673)
    (row 1.3403141896637998 -0.42257122959194704)
    (row 1.286432210124115 -0.3633754347673556)
    (row 1.2367150214269895 -0.30651309567405577)
    (row 1.1906977166711752 -0.25180720160537634)
    (row 1.1479821020556429 -0.19910014943794563)
    (row 1.1082251448272158 -0.14825100623281615)
    (row 1.0711297413057381 -0.09913323807318392)
    (row 1.036437278977283 -0.051632812977629436)
    (row 1.0 0.0)
    (row 0.9492859795739057 0.07508531937943004)
    (row 0.8951049428609004 0.15987125980713107)
    (row 0.8476821620351103 0.2384046664317681)
    (row 0.8050314851692001 0.31288288605863257)
    (row 0.7664671008843108 0.38370422656453185)
    (row 0.731428603316328 0.451211048935815)))

;: Evaluate log2(x) in binary64 for the binary32 pow reduction; `ix` is the
;: bit pattern of a positive finite binary32 x, pre-normalized with the sign
;: bit as exponent for subnormals. Mirrors musl powf.c `log2_inline` with
;: POWF_SCALE 1 (TOINT intrinsics off), so the upstream scale multipliers are
;: the identity.
(define (math-powf-log2 [ix : u32]) : f64
  (let
    [tmp : u32 (- ix (cast 0x3f330000 : u32))]
    [index : i64 (cast (% (shr tmp 19) (cast 16 : u32)) : i64)]
    [top : u32 (bit-and tmp (cast 0xff800000 : u32))]
    [iz : u32 (- ix top)]
    [k : i64 (cast (shr (cast top : i32) 23) : i64)]
    [entry : MathPowLogF32TableEntry (math-powf-table-entry index)]
    [invc : f64 (stdlib.math.f64-from-bits entry.invc-bits)]
    [logc : f64 (stdlib.math.f64-from-bits entry.logc-bits)]
    [z : f64 (cast (stdlib.math.f32-from-bits iz) : f64)]
    [r : f64 (- (* z invc) 1.0)]
    [y0 : f64 (+ logc (cast k : f64))]
    [r2 : f64 (* r r)]
    [y : f64 (+ (* 0.28845758110921399 r) -0.36092606229713164)]
    [p : f64 (+ (* 0.48089848147257702 r) -0.72134746750062906)]
    [r4 : f64 (* r2 r2)]
    [q : f64 (+ (* 1.4426950408774342 r) y0)]
    (begin
      (set! q (+ (* p r2) q))
      (set! y (+ (* y r4) q))
      y)))

;: Compute 2^(y*log2(x)) for the binary32 pow reduction. Mirrors musl powf.c
;: `exp2_inline` on the non-TOINT path: the shift constant is
;: __exp2f_data.shift_scaled (0x1.8p+47) and the polynomial is the unscaled
;: __exp2f_data.poly. The 32-entry `__exp2f_data.tab` is every fourth
;: `__exp_data` scale row (verified against exp2f_data.c, the same reuse the
;: f32-exp port relies on), so the shared accessor supplies the scale bits.
(define (math-powf-exp2 [xd : f64] [sign-bias : u32]) : f32
  (let
    [rounded : f64 (+ xd 211106232532992.0)]
    [ki : u64 (stdlib.math.f64-to-bits rounded)]
    [kd : f64 (- rounded 211106232532992.0)]
    [r : f64 (- xd kd)]
    [entry : MathExpF64TableEntry
      (math-exp-f64-table-entry (* (cast (% ki (cast 32 : u64)) : i64) 4))]
    [ski : u64 (+ ki (cast sign-bias : u64))]
    [t : u64 (+ entry.scale-bits (shl ski 47))]
    [s : f64 (stdlib.math.f64-from-bits t)]
    [z : f64 (+ (* 0.055503615593415351 r) 0.2402284522445722)]
    [r2 : f64 (* r r)]
    [y : f64 (+ (* 0.69314718069162029 r) 1.0)]
    (begin
      (set! y (+ (* z r2) y))
      (set! y (* y s))
      (cast y : f32))))

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
            (begin
              (if (and
                (!= (bit-and ix (cast 0x80000000 : u32)) (cast 0 : u32))
                (= (math-powf-checkint iy) 1))
                (set! x2 (* x2 (cast -1.0 : f32)))
                unit)
              (if (!= (bit-and iy (cast 0x80000000 : u32)) (cast 0 : u32))
                (/ (cast 1.0 : f32) x2)
                x2)))]
        [else
          (begin
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
                (if (< ix (cast 0x00800000 : u32))
                  (begin
                    (set!
                      ix
                      (bit-and
                        (stdlib.math.f32-to-bits (* x (cast 8388608.0 : f32)))
                        (cast 0x7fffffff : u32)))
                    (set! ix (- ix (shl (cast 23 : u32) 23))))
                  unit)
                (math-powf-main ix y sign-bias))))])
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
    [(= index 0) 1.5707962512969971]
    [(= index 1) 7.5497894158615964e-08]
    [(= index 2) 5.3903025299577648e-15]
    [(= index 3) 3.2820034158079129e-22]
    [(= index 4) 1.2706557530806761e-29]
    [(= index 5) 1.2293330898111133e-36]
    [(= index 6) 2.7337005381646456e-44]
    [else 2.1674168387780482e-51]))

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
          (set!
            (array-ref f i)
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
          (set! (array-ref q i) fw)
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
              (set! (array-ref iq i) (cast (- z (* 16777216.0 fw)) : i64))
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
                (set!
                  (array-ref iq (- jz 1))
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
                        (set! (array-ref iq i) (- 0x1000000 j)))
                      unit)
                    (set! (array-ref iq i) (- 0xffffff j)))
                  (set! i (+ i 1))))
              (if (= q0 1)
                (set!
                  (array-ref iq (- jz 1))
                  (bit-and (array-ref iq (- jz 1)) 0x7fffff))
                (if (= q0 2)
                  (set!
                    (array-ref iq (- jz 1))
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
                      (set!
                        (array-ref f (+ jx i))
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
                      (set! (array-ref q i) fw)
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
              (set! (array-ref iq jz) (cast (- z (* 16777216.0 fw)) : i64))
              (set! jz (+ jz 1))
              (set! q0 (+ q0 24))
              (set! (array-ref iq jz) (cast fw : i64)))
            (set! (array-ref iq jz) (cast z : i64)))))
      ;; Convert integer limbs back to scaled floating values.
      (set! fw (stdlib.math.f64-scalbn 1.0 q0))
      (set! i jz)
      (while (>= i 0)
        (begin
          (set! (array-ref q i) (* fw (cast (array-ref iq i) : f64)))
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
          (set! (array-ref fq (- jz i)) fw)
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
          (if (> (- r w) 0.78539816339744828)
            (begin
              (set! n (+ n 1))
              (set! fn (+ fn 1.0))
              (set! r (- value (* fn 1.5707963267341256)))
              (set! w (* fn 6.0771005065061922e-11)))
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
            (set! w (* fn 6.077100506303966e-11))
            (set! r (- t w))
            (set! w (- (* fn 2.0222662487959506e-21) (- (- t r) w)))
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
                (set! w (* fn 2.0222662487111665e-21))
                (set! r (- t w))
                (set! w (- (* fn 8.4784276603688996e-32) (- (- t r) w)))
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
                (- 0 large.quadrant)
                (- 0.0 large.hi)
                (- 0.0 large.lo))
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
          (if (> remainder 0.78539818525314331)
            (begin
              (set! n (+ n 1))
              (set! fn (+ fn 1.0))
              (set!
                remainder
                (-
                  (- wide (* fn 1.5707963109016418))
                  (* fn 1.5893254773528196e-08))))
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
    (begin
      (if big
        (begin
          (if negative
            (begin
              (set! x (- 0.0 x))
              (set! tail (- 0.0 tail)))
            unit)
          (set! x (+ (- 0.78539816339744828 x) (- 3.061616997868383e-17 tail)))
          (set! tail 0.0))
        unit)
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
                          (+
                            7.1407249138260819e-05
                            (* w 2.5907305186363371e-05))))))))))))
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
            (+ a0 (* reciprocal (+ 1.0 (+ (* a0 w0) (* a0 correction)))))))))))

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
    (begin
      (while (not (= rest (cast 0 : u64)))
        (begin
          (set! rest (shr rest 1))
          (set! bits (+ bits 1))))
      bits)))

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
    (begin
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
              (=
                (bit-and (math-fma-wide-shr-low magnitude (- shift 1)) one)
                one)]
            [sticky? : bool (math-fma-wide-low-bits-set? magnitude (- shift 1))]
            [odd? : bool (= (bit-and kept one) one)]
            (set!
              significand
              (if (and half? (or sticky? odd?))
                (+ kept one)
                kept)))))
      (if (= significand (shl one precision))
        (begin
          (set! significand (shr significand 1))
          (set! quantum (+ quantum 1)))
        unit)
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
                (- significand (shl one (- precision 1)))))))))))

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
    (begin
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
          (stdlib.math.f64-nan?
            (stdlib.math.f64-tan (stdlib.math.f64-quiet-nan)))
          (stdlib.math.f32-nan?
            (stdlib.math.f32-sin (stdlib.math.f32-positive-infinity)))
          (stdlib.math.f32-nan?
            (stdlib.math.f32-cos (stdlib.math.f32-negative-infinity)))
          (stdlib.math.f32-nan?
            (stdlib.math.f32-tan (stdlib.math.f32-quiet-nan))))
        "math-trig-reduction-and-special-values: (and (f64-nan? (f64-sin (f64-positive-infinity))) (f64-na..."))))

(test
  math-i64-api
  (begin
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
      "math-i64-api: (not (i64-positive? 0))")))

(test
  math-f64-api
  (let
    [abs-neg : f64 -2.5]
    [abs-want : f64 2.5]
    (begin
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
        "math-f64-api: (not (f64-negative? 0.0))"))))

(test
  math-f32-api
  (let
    [neg : f32 -2.5]
    [zero : f32 0.0]
    [pos : f32 2.5]
    [want : f32 2.5]
    (begin
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
        "math-f32-api: (= (abs neg) want)"))))

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
    (begin
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
        "math-float-sqrt: (and (f64-nan? (f64-sqrt -1.0)) (f64-nan? (f64-sqrt (f64-..."))))

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
    (begin
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
        "math-float-mul-add: (= (f64-mul-add 2.0 3.0 (f64-negative-infinity)) (f64-neg..."))))

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
    (begin
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
        (=
          (stdlib.math.f64-to-bits payload-nan)
          (cast 0x7ff8000000001234 : u64))
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
          (stdlib.math.f64-to-bits
            (stdlib.math.f64-copy-sign 3.0 negative-zero))
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
        "math-f64-ieee-foundation: (f64-nan? (f64-scalbn payload-nan 99))"))))

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
    (begin
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
        "math-f32-ieee-foundation: (f32-nan? (f32-scalbn payload-nan 99))"))))

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
  (begin
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
      "math-pow-f64-special: (f64-nan? (f64-pow (f64-from-bits (cast 0xc02000000000000...")))

(test
  math-pow-f32-special
  (begin
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
      "math-pow-f32-special: (f32-nan? (f32-pow (f32-from-bits (cast 0xc0000000 : u32)...")))