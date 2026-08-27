(import stdlib.format)
(import stdlib.math)
(import stdlib.string)

(defstruct ExponentEvalState
  (calls i64))

(define (exponent-counted
  [state : (&mut state ExponentEvalState)]
  [value : i64]) : i64
  (begin
    (set! state.calls (+ state.calls 1))
    value))

(define (format-borrowed-i64 [value : (& value i64)]) : String
  (format.format "{:.2e}" value))

(define (format-borrowed-f32 [value : (& value f32)]) : String
  (format.format "{:E}" value))

(define (integer-widths-ok?) : bool
  (and
    (string.eq (format.format "{:e}" (cast 0 : i8)) "0e0")
    (string.eq (format.format "{:e}" (cast 1 : i8)) "1e0")
    (string.eq (format.format "{:e}" (cast -128 : i8)) "-1.28e2")
    (string.eq (format.format "{:e}" (cast 127 : i8)) "1.27e2")
    (string.eq (format.format "{:e}" (cast 0 : i16)) "0e0")
    (string.eq (format.format "{:e}" (cast 1 : i16)) "1e0")
    (string.eq (format.format "{:e}" (cast -32768 : i16)) "-3.2768e4")
    (string.eq (format.format "{:e}" (cast 32767 : i16)) "3.2767e4")
    (string.eq (format.format "{:e}" (cast 0 : i32)) "0e0")
    (string.eq (format.format "{:e}" (cast 1 : i32)) "1e0")
    (string.eq (format.format "{:e}" (cast -2147483648 : i32)) "-2.147483648e9")
    (string.eq (format.format "{:e}" (cast 2147483647 : i32)) "2.147483647e9")
    (string.eq (format.format "{:e}" (cast 0 : i64)) "0e0")
    (string.eq (format.format "{:e}" (cast 1 : i64)) "1e0")
    (string.eq
      (format.format "{:e}" (cast -9223372036854775808 : i64))
      "-9.223372036854775808e18")
    (string.eq
      (format.format "{:e}" (cast 9223372036854775807 : i64))
      "9.223372036854775807e18")
    (string.eq (format.format "{:e}" (cast 0 : u8)) "0e0")
    (string.eq (format.format "{:e}" (cast 1 : u8)) "1e0")
    (string.eq (format.format "{:e}" (cast 255 : u8)) "2.55e2")
    (string.eq (format.format "{:e}" (cast 0 : u16)) "0e0")
    (string.eq (format.format "{:e}" (cast 1 : u16)) "1e0")
    (string.eq (format.format "{:e}" (cast 65535 : u16)) "6.5535e4")
    (string.eq (format.format "{:e}" (cast 0 : u32)) "0e0")
    (string.eq (format.format "{:e}" (cast 1 : u32)) "1e0")
    (string.eq (format.format "{:e}" (cast 4294967295 : u32)) "4.294967295e9")
    (string.eq (format.format "{:e}" (cast 0 : u64)) "0e0")
    (string.eq (format.format "{:e}" (cast 1 : u64)) "1e0")
    (string.eq
      (format.format "{:e}" (cast 18446744073709551615 : u64))
      "1.8446744073709551615e19")))

(define (integer-precision-ok?) : bool
  (let
    [dynamic-precision : i64 3]
    (and
      (string.eq (format.format "{:.0e}" (cast 9999 : i32)) "1e4")
      (string.eq (format.format "{:.1e}" (cast 9850 : i32)) "9.8e3")
      (string.eq (format.format "{:.1e}" (cast 9950 : i32)) "1.0e4")
      (string.eq (format.format "{:.3e}" (cast 12345 : i32)) "1.234e4")
      (string.eq (format.format "{:.3e}" (cast 999 : i32)) "9.990e2")
      (string.eq (format.format "{:.3E}" (cast -42 : i32)) "-4.200E1")
      (string.eq
        (format.format "{0:.1$e}" (cast 12345 : i32) dynamic-precision)
        "1.234e4")
      (string.eq
        (format.format "{:.*e}" dynamic-precision (cast 12345 : i32))
        "1.234e4")
      (string.eq
        (format.format
          "{value:.precision$E}"
          (format.named value (cast 12345 : i32))
          (format.named precision dynamic-precision))
        "1.234E4"))))

(define (f64-exponent-ok?) : bool
  (and
    (string.eq
      (format.format "{:e}" (math.f64-from-bits 0x0000000000000000))
      "0e0")
    (string.eq
      (format.format "{:e}" (math.f64-from-bits 0x8000000000000000))
      "-0e0")
    (string.eq (format.format "{:e}" (cast 1.0 : f64)) "1e0")
    (string.eq (format.format "{:e}" (cast -1.0 : f64)) "-1e0")
    (string.eq (format.format "{:e}" (cast 1.25 : f64)) "1.25e0")
    (string.eq (format.format "{:e}" (cast 0.00001 : f64)) "1e-5")
    (string.eq
      (format.format "{:e}" (cast 100000000000000000000.0 : f64))
      "1e20")
    (string.eq
      (format.format "{:e}" (math.f64-from-bits 0x0000000000000001))
      "5e-324")
    (string.eq
      (format.format "{:e}" (math.f64-from-bits 0x000fffffffffffff))
      "2.225073858507201e-308")
    (string.eq
      (format.format "{:e}" (math.f64-from-bits 0x0010000000000000))
      "2.2250738585072014e-308")
    (string.eq
      (format.format "{:e}" (math.f64-from-bits 0x7fefffffffffffff))
      "1.7976931348623157e308")
    (string.eq
      (format.format "{:e}" (math.f64-from-bits 0x7ff0000000000000))
      "inf")
    (string.eq
      (format.format "{:E}" (math.f64-from-bits 0xfff0000000000000))
      "-inf")
    (string.eq
      (format.format "{:E}" (math.f64-from-bits 0xfff8000000001234))
      "NaN")))

(define (f32-exponent-ok?) : bool
  (and
    (string.eq
      (format.format "{:e}" (math.f32-from-bits (cast 0x00000000 : u32)))
      "0e0")
    (string.eq
      (format.format "{:e}" (math.f32-from-bits (cast 0x80000000 : u32)))
      "-0e0")
    (string.eq (format.format "{:e}" (cast 1.0 : f32)) "1e0")
    (string.eq
      (format.format "{:e}" (math.f32-from-bits (cast 0x3f9e0651 : u32)))
      "1.2345678e0")
    (string.eq
      (format.format "{:e}" (math.f32-from-bits (cast 0x00000001 : u32)))
      "1e-45")
    (string.eq
      (format.format "{:e}" (math.f32-from-bits (cast 0x007fffff : u32)))
      "1.1754942e-38")
    (string.eq
      (format.format "{:e}" (math.f32-from-bits (cast 0x00800000 : u32)))
      "1.1754944e-38")
    (string.eq
      (format.format "{:e}" (math.f32-from-bits (cast 0x7f7fffff : u32)))
      "3.4028235e38")
    (string.eq
      (format.format "{:e}" (math.f32-from-bits (cast 0x7f800000 : u32)))
      "inf")
    (string.eq
      (format.format "{:E}" (math.f32-from-bits (cast 0xff800000 : u32)))
      "-inf")
    (string.eq
      (format.format "{:E}" (math.f32-from-bits (cast 0xffc01234 : u32)))
      "NaN")))

(define (float-precision-ok?) : bool
  (and
    (string.eq (format.format "{:.0e}" (cast 9.999 : f64)) "1e1")
    (string.eq (format.format "{:.1e}" (cast 1.25 : f64)) "1.2e0")
    (string.eq (format.format "{:.1e}" (cast 1.75 : f64)) "1.8e0")
    (string.eq (format.format "{:.3e}" (cast 1.25 : f64)) "1.250e0")
    (string.eq
      (format.format "{:.3e}" (math.f64-from-bits 0x0000000000000001))
      "4.941e-324")
    (string.eq
      (format.format "{:.3e}" (math.f32-from-bits (cast 0x00000001 : u32)))
      "1.401e-45")
    (string.eq
      (format.format "{:.3e}" (math.f32-from-bits (cast 0x3f9e0651 : u32)))
      "1.235e0")
    (string.eq
      (format.format "{:.3e}" (math.f64-from-bits 0x7ff0000000000000))
      "inf")
    (string.eq
      (format.format "{:.3E}" (math.f64-from-bits 0xfff8000000001234))
      "NaN")
    (string.eq
      (format.format "{:+012.3e}" (math.f64-from-bits 0x7ff8000000001234))
      "000000000NaN")))

(define (options-and-evaluation-ok?) : bool
  (let
    [state : ExponentEvalState (ExponentEvalState 0)]
    [borrowed-integer : i64 -42]
    [borrowed-float : f32 (cast 1.25 : f32)]
    [counted : String
      (format.format "{:e}" (exponent-counted (&mut state) 1250))]
    (and
      (string.eq (format.format "{:+012.3e}" (cast 12345 : i32)) "+00001.234e4")
      (string.eq (format.format "{:*^12.3E}" (cast -42 : i32)) "**-4.200E1**")
      (string.eq (format.format "{:>12.3e}" (cast 12345 : i32)) "     1.234e4")
      (string.eq (format.format "{:#e}" (cast 1000 : i32)) "1e3")
      (string.eq (format.format "{:#.0e}" (cast 1000 : i32)) "1e3")
      (string.eq (format-borrowed-i64 (& borrowed-integer)) "-4.20e1")
      (string.eq (format-borrowed-f32 (& borrowed-float)) "1.25E0")
      (string.eq counted "1.25e3")
      (= state.calls 1)
      (string.eq
        (format.format "{}" (cast 100000000000000000000.0 : f64))
        "100000000000000000000")
      (string.eq (format.format "{:.2}" (cast 1.25 : f64)) "1.25"))))

(define (large-precision-ok?) : bool
  (let
    [text : String (format.format "{:.400e}" (cast 1.0 : f64))]
    [index : i64 2]
    [ok : bool
      (and
        (= (string.string-length (& text)) 404)
        (= (cast (string.string-ref (& text) 0) : i64) 49)
        (= (cast (string.string-ref (& text) 1) : i64) 46)
        (= (cast (string.string-ref (& text) 402) : i64) 101)
        (= (cast (string.string-ref (& text) 403) : i64) 48))]
    (begin
      (while (and ok (< index 402))
        (begin
          (set! ok (= (cast (string.string-ref (& text) index) : i64) 48))
          (set! index (+ index 1))))
      ok)))

(define (main) : i64
  (cond
    [(not (integer-widths-ok?)) 1]
    [(not (integer-precision-ok?)) 2]
    [(not (f64-exponent-ok?)) 3]
    [(not (f32-exponent-ok?)) 4]
    [(not (float-precision-ok?)) 5]
    [(not (options-and-evaluation-ok?)) 6]
    [(not (large-precision-ok?)) 7]
    [else 42]))