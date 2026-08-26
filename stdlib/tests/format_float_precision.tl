(import stdlib.array)
(import stdlib.format)
(import stdlib.math)
(import stdlib.string)

(define (fixed-f64 [bits : u64] [precision : i64]) : String
  (format.format "{0:.1$}" (math.f64-from-bits bits) precision))

(define (fixed-f32 [bits : u32] [precision : i64]) : String
  (format.format "{0:.1$}" (math.f32-from-bits bits) precision))

(define (fill-f64-fixed-cases
  [bits : (&mut bits (__tl_dyn-array u64))]
  [precision : (&mut precision (__tl_dyn-array i64))]
  [expected : (&mut expected (__tl_dyn-array String))]) : unit
  (begin
    (set! (array-ref bits 0) 0x0000000000000000)
    (set! (array-ref precision 0) 0)
    (set! (array-ref expected 0) "0")
    (set! (array-ref bits 1) 0x8000000000000000)
    (set! (array-ref precision 1) 3)
    (set! (array-ref expected 1) "-0.000")
    (set! (array-ref bits 2) 0x3ff4000000000000)
    (set! (array-ref precision 2) 1)
    (set! (array-ref expected 2) "1.2")
    (set! (array-ref bits 3) 0x3ffc000000000000)
    (set! (array-ref precision 3) 1)
    (set! (array-ref expected 3) "1.8")
    (set! (array-ref bits 4) 0x4004000000000000)
    (set! (array-ref precision 4) 0)
    (set! (array-ref expected 4) "2")
    (set! (array-ref bits 5) 0x400c000000000000)
    (set! (array-ref precision 5) 0)
    (set! (array-ref expected 5) "4")
    (set! (array-ref bits 6) 0x3ff3ffffffffffff)
    (set! (array-ref precision 6) 1)
    (set! (array-ref expected 6) "1.2")
    (set! (array-ref bits 7) 0x3ff4000000000001)
    (set! (array-ref precision 7) 1)
    (set! (array-ref expected 7) "1.3")
    (set! (array-ref bits 8) (__tl_float_to_bits (cast 9.999 : f64)))
    (set! (array-ref precision 8) 2)
    (set! (array-ref expected 8) "10.00")
    (set! (array-ref bits 9) 0x7ff0000000000000)
    (set! (array-ref precision 9) 2)
    (set! (array-ref expected 9) "inf")
    (set! (array-ref bits 10) 0xfff0000000000000)
    (set! (array-ref precision 10) 2)
    (set! (array-ref expected 10) "-inf")
    (set! (array-ref bits 11) 0xfff8000000001234)
    (set! (array-ref precision 11) 2)
    (set! (array-ref expected 11) "NaN")
    (set! (array-ref bits 12) 0x7fefffffffffffff)
    (set! (array-ref precision 12) 0)
    (set!
      (array-ref expected 12)
      "179769313486231570814527423731704356798070567525844996598917476803157260780028538760589558632766878171540458953514382464234321326889464182768467546703537516986049910576551282076245490090389328944075868508455133942304583236903222948165808559332123348274797826204144723168738177180919299881250404026184124858368")
    (set! (array-ref bits 13) 0x0000000000000001)
    (set! (array-ref precision 13) 324)
    (set!
      (array-ref expected 13)
      "0.000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000005")
    (set! (array-ref bits 14) 0x0010000000000000)
    (set! (array-ref precision 14) 324)
    (set!
      (array-ref expected 14)
      "0.000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000022250738585072014")
    unit))

(define (f64-fixed-table-ok?) : bool
  (let
    [count : i64 15]
    [bits : (__tl_dyn-array u64) (array.make-array u64 count)]
    [precision : (__tl_dyn-array i64) (array.make-array i64 count)]
    [expected : (__tl_dyn-array String) (array.make-array String count)]
    [i : i64 0]
    [ok : bool true]
    (begin
      (fill-f64-fixed-cases (&mut bits) (&mut precision) (&mut expected))
      (while (and ok (< i count))
        (begin
          (set!
            ok
            (string.eq
              (fixed-f64 (array-ref bits i) (array-ref precision i))
              (array-ref expected i)))
          (set! i (+ i 1))))
      ok)))

(define (half-even-property-ok?) : bool
  (let
    [integer : i64 -64]
    [ok : bool true]
    (begin
      (while (and ok (<= integer 64))
        (let
          [value : f64 (+ (cast integer : f64) (cast 0.5 : f64))]
          [expected : i64
            (if (= (% integer 2) 0)
              integer
              (+ integer 1))]
          [expected-text : String
            (if (and (= expected 0) (< integer 0))
              "-0"
              (string.int->string expected))]
          (begin
            (set! ok (string.eq (format.format "{:.0}" value) expected-text))
            (set! integer (+ integer 1)))))
      ok)))

(define (minimum-subnormal-below-half-ok?) : bool
  (let
    [got : String (fixed-f64 0x0000000000000001 323)]
    [i : i64 2]
    [ok : bool
      (and
        (= (string.string-length (& got)) 325)
        (= (cast (string.string-ref (& got) 0) : i64) 48)
        (= (cast (string.string-ref (& got) 1) : i64) 46))]
    (begin
      (while (and ok (< i 325))
        (begin
          (set! ok (= (cast (string.string-ref (& got) i) : i64) 48))
          (set! i (+ i 1))))
      ok)))

(define (exact-subnormal-scale-ok?) : bool
  (let
    [f64-text : String (fixed-f64 0x0000000000000001 1074)]
    [f32-text : String (fixed-f32 (cast 0x00000001 : u32) 149)]
    (and
      (= (string.string-length (& f64-text)) 1076)
      (= (cast (string.string-ref (& f64-text) 1072) : i64) 53)
      (= (cast (string.string-ref (& f64-text) 1073) : i64) 54)
      (= (cast (string.string-ref (& f64-text) 1074) : i64) 50)
      (= (cast (string.string-ref (& f64-text) 1075) : i64) 53)
      (= (string.string-length (& f32-text)) 151)
      (= (cast (string.string-ref (& f32-text) 147) : i64) 51)
      (= (cast (string.string-ref (& f32-text) 148) : i64) 49)
      (= (cast (string.string-ref (& f32-text) 149) : i64) 50)
      (= (cast (string.string-ref (& f32-text) 150) : i64) 53))))

(define (fill-f32-fixed-cases
  [bits : (&mut bits (__tl_dyn-array u32))]
  [precision : (&mut precision (__tl_dyn-array i64))]
  [expected : (&mut expected (__tl_dyn-array String))]) : unit
  (begin
    (set! (array-ref bits 0) (cast 0x80000000 : u32))
    (set! (array-ref precision 0) 3)
    (set! (array-ref expected 0) "-0.000")
    (set! (array-ref bits 1) (cast 0x3fa00000 : u32))
    (set! (array-ref precision 1) 1)
    (set! (array-ref expected 1) "1.2")
    (set! (array-ref bits 2) (cast 0x3f9e0651 : u32))
    (set! (array-ref precision 2) 8)
    (set! (array-ref expected 2) "1.23456776")
    (set! (array-ref bits 3) (cast 0x7f7fffff : u32))
    (set! (array-ref precision 3) 0)
    (set! (array-ref expected 3) "340282346638528859811704183484516925440")
    (set! (array-ref bits 4) (cast 0x00000001 : u32))
    (set! (array-ref precision 4) 45)
    (set!
      (array-ref expected 4)
      "0.000000000000000000000000000000000000000000001")
    (set! (array-ref bits 5) (cast 0x00800000 : u32))
    (set! (array-ref precision 5) 45)
    (set!
      (array-ref expected 5)
      "0.000000000000000000000000000000000000011754944")
    (set! (array-ref bits 6) (cast 0x7f800000 : u32))
    (set! (array-ref precision 6) 4)
    (set! (array-ref expected 6) "inf")
    (set! (array-ref bits 7) (cast 0xffc01234 : u32))
    (set! (array-ref precision 7) 4)
    (set! (array-ref expected 7) "NaN")
    unit))

(define (f32-fixed-table-ok?) : bool
  (let
    [count : i64 8]
    [bits : (__tl_dyn-array u32) (array.make-array u32 count)]
    [precision : (__tl_dyn-array i64) (array.make-array i64 count)]
    [expected : (__tl_dyn-array String) (array.make-array String count)]
    [i : i64 0]
    [ok : bool true]
    (begin
      (fill-f32-fixed-cases (&mut bits) (&mut precision) (&mut expected))
      (while (and ok (< i count))
        (begin
          (set!
            ok
            (string.eq
              (fixed-f32 (array-ref bits i) (array-ref precision i))
              (array-ref expected i)))
          (set! i (+ i 1))))
      ok)))

(define (count-forms-ok?) : bool
  (let
    [precision : i64 3]
    [value : f64 (cast 1.25 : f64)]
    [inline : String (format.format "{:.3}" value)]
    [indexed : String (format.format "{0:.1$}" value precision)]
    [named : String
      (format.format
        "{value:.precision$}"
        (format.named value value)
        (format.named precision precision))]
    [star : String (format.format "{:.*}" precision value)]
    [max-precision : i64 9223372036854775807]
    [infinite : String
      (format.format
        "{0:.1$}"
        (math.f64-from-bits 0x7ff0000000000000)
        max-precision)]
    (and
      (string.eq inline "1.250")
      (string.eq indexed inline)
      (string.eq named inline)
      (string.eq star inline)
      (string.eq infinite "inf")
      (string.eq (format.format "{:#.0}" value) "1")
      (string.eq (format.format "{:#.2}" (cast 1.0 : f64)) "1.00")
      (string.eq (format.format "{:+08.2}" (cast 1.5 : f64)) "+0001.50")
      (string.eq (format.format "{:08.2}" (cast -0.0 : f64)) "-0000.00"))))

(define (large-precision-ok?) : bool
  (let
    [precision : i64 400]
    [got : String (fixed-f64 0x3ff0000000000000 precision)]
    [i : i64 2]
    [ok : bool
      (and
        (= (string.string-length (& got)) 402)
        (= (cast (string.string-ref (& got) 0) : i64) 49)
        (= (cast (string.string-ref (& got) 1) : i64) 46))]
    (begin
      (while (and ok (< i 402))
        (begin
          (set! ok (= (cast (string.string-ref (& got) i) : i64) 48))
          (set! i (+ i 1))))
      ok)))

(define (main) : i64
  (cond
    [(not (f64-fixed-table-ok?)) 1]
    [(not (f32-fixed-table-ok?)) 2]
    [(not (half-even-property-ok?)) 3]
    [(not (minimum-subnormal-below-half-ok?)) 4]
    [(not (exact-subnormal-scale-ok?)) 5]
    [(not (count-forms-ok?)) 6]
    [(not (large-precision-ok?)) 7]
    [else 42]))