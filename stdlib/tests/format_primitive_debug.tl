(import stdlib.format)
(import stdlib.math)
(import stdlib.string)

(defstruct DebugEvalState
  (calls i64))

(define (debug-counted [state : (&mut state DebugEvalState)] [value : i16]) : i16
  (begin
    (set! state.calls (+ state.calls 1))
    value))

(define (debug-shared-i16 [value : (& value i16)]) : String
  (format.format "{:?}" value))

(define (debug-shared-unit [value : (& value unit)]) : String
  (format.format "{:?}" value))

(define (debug-mutable-i16 [value : (&mut value i16)]) : String
  (format.format "{:X?}" value))

(define (debug-nested-i16 [value : (& outer (& inner i16))]) : String
  (format.format "{:>6?}" value))

(define (debug-shared-pointer [value : (& value (Ptr i64))]) : String
  (unsafe
    (format.format "{:?}" value)))

(define (debug-mutable-pointer [value : (&mut value (Ptr i64))]) : String
  (unsafe
    (format.format "{:X?}" value)))

(define (debug-options-abi-ok?) : bool
  (let
    [common : format.FormatOptions
      (format.FormatOptions ' ' 0 0 true false 0 false 0)]
    [options : format.DebugOptions
      (format.DebugOptions common (format.DebugUpperHex))]
    (and
      options.format-options.alternate
      (match options.integer-mode
        [(format.DebugUpperHex) true]
        [_ false]))))

(define (debug-integer-ok?) : bool
  (and
    (string.eq (format.format "{:?}" (cast -128 : i8)) "-128")
    (string.eq (format.format "{:x?}" (cast -1 : i8)) "ff")
    (string.eq (format.format "{:#X?}" (cast -1 : i16)) "0xFFFF")
    (string.eq (format.format "{:x?}" (cast -1 : i32)) "ffffffff")
    (string.eq (format.format "{:X?}" (cast -1 : i64)) "FFFFFFFFFFFFFFFF")
    (string.eq (format.format "{:x?}" (cast 255 : u8)) "ff")
    (string.eq (format.format "{:X?}" (cast 65535 : u16)) "FFFF")
    (string.eq (format.format "{:#x?}" (cast 4294967295 : u32)) "0xffffffff")
    (string.eq
      (format.format "{:#X?}" (cast 18446744073709551615 : u64))
      "0xFFFFFFFFFFFFFFFF")
    (string.eq (format.format "{:+#012x?}" (cast 42 : i64)) "+0x00000002a")
    (string.eq (format.format "{:.0?}" (cast -42 : i64)) "-42")))

(define (debug-integer-boundaries-ok?) : bool
  (and
    (string.eq
      (format.format "{0:?}|{0:x?}|{0:X?}" (cast -128 : i8))
      "-128|80|80")
    (string.eq
      (format.format "{0:?}|{0:x?}|{0:X?}" (cast 127 : i8))
      "127|7f|7F")
    (string.eq
      (format.format "{0:?}|{0:#x?}|{0:#X?}" (cast -1 : i8))
      "-1|0xff|0xFF")
    (string.eq
      (format.format "{0:?}|{0:x?}|{0:X?}" (cast -32768 : i16))
      "-32768|8000|8000")
    (string.eq
      (format.format "{0:?}|{0:x?}|{0:X?}" (cast 32767 : i16))
      "32767|7fff|7FFF")
    (string.eq
      (format.format "{0:?}|{0:#x?}|{0:#X?}" (cast -1 : i16))
      "-1|0xffff|0xFFFF")
    (string.eq
      (format.format "{0:?}|{0:x?}|{0:X?}" (cast -2147483648 : i32))
      "-2147483648|80000000|80000000")
    (string.eq
      (format.format "{0:?}|{0:x?}|{0:X?}" (cast 2147483647 : i32))
      "2147483647|7fffffff|7FFFFFFF")
    (string.eq
      (format.format "{0:?}|{0:#x?}|{0:#X?}" (cast -1 : i32))
      "-1|0xffffffff|0xFFFFFFFF")
    (string.eq
      (format.format "{0:?}|{0:x?}|{0:X?}" (cast -9223372036854775808 : i64))
      "-9223372036854775808|8000000000000000|8000000000000000")
    (string.eq
      (format.format "{0:?}|{0:x?}|{0:X?}" (cast 9223372036854775807 : i64))
      "9223372036854775807|7fffffffffffffff|7FFFFFFFFFFFFFFF")
    (string.eq
      (format.format "{0:?}|{0:#x?}|{0:#X?}" (cast -1 : i64))
      "-1|0xffffffffffffffff|0xFFFFFFFFFFFFFFFF")
    (string.eq
      (format.format "{0:?}|{0:#x?}|{0:#X?}" (cast 255 : u8))
      "255|0xff|0xFF")
    (string.eq
      (format.format "{0:?}|{0:#x?}|{0:#X?}" (cast 65535 : u16))
      "65535|0xffff|0xFFFF")
    (string.eq
      (format.format "{0:?}|{0:#x?}|{0:#X?}" (cast 4294967295 : u32))
      "4294967295|0xffffffff|0xFFFFFFFF")
    (string.eq
      (format.format "{0:?}|{0:#x?}|{0:#X?}" (cast 18446744073709551615 : u64))
      "18446744073709551615|0xffffffffffffffff|0xFFFFFFFFFFFFFFFF")
    (string.eq (format.format "{:x?}|{:X?}" (cast 0 : u8) (cast 0 : u64)) "0|0")))

(define (debug-text-and-leaf-ok?) : bool
  (and
    (string.eq (format.format "{:?}" true) "true")
    (string.eq (format.format "{:>6.1?}" true) "     t")
    (string.eq (format.format "{:X?}" false) "false")
    (string.eq (format.format "{:?}" unit) "()")
    (string.eq (format.format "{:>5.1?}" unit) "    (")
    (string.eq (format.format "{:?}" "a\n") "\"a\\n\"")
    (string.eq (format.format "{:>20.0?}" "a\n") "\"a\\n\"")
    (string.eq (format.format "{:x?}" '\n') "'\\n'")
    (string.eq (format.format "{:+08X?}" 'A') "'A'")))

(define (debug-float-ok?) : bool
  (and
    (string.eq (format.format "{:?}" (cast 1.0 : f64)) "1.0")
    (string.eq (format.format "{:?}" (cast 0.0 : f64)) "0.0")
    (string.eq (format.format "{:?}" (cast -0.0 : f64)) "-0.0")
    (string.eq (format.format "{:?}" (cast 0.00001 : f64)) "1e-5")
    (string.eq (format.format "{:?}" (cast 0.0001 : f64)) "0.0001")
    (string.eq (format.format "{:?}" (cast 10000000000000000.0 : f64)) "1e16")
    (string.eq
      (format.format "{:?}" (cast 1000000000000000.0 : f64))
      "1000000000000000.0")
    (string.eq (format.format "{:.0?}" (cast 1.5 : f64)) "2")
    (string.eq (format.format "{:.2X?}" (cast 1.25 : f64)) "1.25")
    (string.eq
      (format.format "{:?}" (math.f64-from-bits 0x7ff0000000000000))
      "inf")
    (string.eq
      (format.format "{:?}" (math.f64-from-bits 0xfff8000000001234))
      "NaN")
    (string.eq
      (format.format "{:?}" (math.f64-from-bits 0xfff0000000000000))
      "-inf")
    (string.eq
      (format.format "{:?}" (math.f64-from-bits 0x0000000000000001))
      "5e-324")
    (string.eq
      (format.format "{:?}" (math.f64-from-bits 0x0010000000000000))
      "2.2250738585072014e-308")
    (string.eq
      (format.format "{:?}" (math.f64-from-bits 0x7fefffffffffffff))
      "1.7976931348623157e308")
    (string.eq
      (format.format "{:.2?}" (math.f64-from-bits 0xfff0000000000000))
      "-inf")
    (string.eq (format.format "{:?}" (cast 1.0 : f32)) "1.0")
    (string.eq (format.format "{:?}" (cast -0.0 : f32)) "-0.0")
    (string.eq (format.format "{:?}" (cast 0.00001 : f32)) "1e-5")
    (string.eq (format.format "{:?}" (cast 0.0001 : f32)) "0.0001")
    (string.eq (format.format "{:?}" (cast 10000000000000000.0 : f32)) "1e16")
    (string.eq
      (format.format "{:?}" (math.f32-from-bits (cast 0x00000001 : u32)))
      "1e-45")
    (string.eq
      (format.format "{:?}" (math.f32-from-bits (cast 0x00800000 : u32)))
      "1.1754944e-38")
    (string.eq
      (format.format "{:?}" (math.f32-from-bits (cast 0x7f7fffff : u32)))
      "3.4028235e38")
    (string.eq
      (format.format "{:?}" (math.f32-from-bits (cast 0xff800000 : u32)))
      "-inf")
    (string.eq
      (format.format "{:?}" (math.f32-from-bits (cast 0xffc01234 : u32)))
      "NaN")))

(define (debug-precision-matrix-ok?) : bool
  (let
    [zero : i64 0]
    [one : i64 1]
    [null : (Ptr i64) (ptr-null : (Ptr i64))]
    [pointer-precision : String
      (unsafe
        (format.format "{0:.1$?}" null zero))]
    (and
      (string.eq (format.format "{0:.1$?}" true zero) "")
      (string.eq (format.format "{0:>5.1$?}" true one) "    t")
      (string.eq (format.format "{0:.1$?}" unit zero) "")
      (string.eq (format.format "{0:>5.1$?}" unit one) "    (")
      (string.eq (format.format "{0:.1$?}" (cast -1 : i8) zero) "-1")
      (string.eq (format.format "{0:.1$?}" (cast -1 : i16) one) "-1")
      (string.eq (format.format "{0:.1$?}" (cast -1 : i32) zero) "-1")
      (string.eq (format.format "{0:.1$?}" (cast -1 : i64) one) "-1")
      (string.eq (format.format "{0:.1$?}" (cast 1 : u8) zero) "1")
      (string.eq (format.format "{0:.1$?}" (cast 1 : u16) one) "1")
      (string.eq (format.format "{0:.1$?}" (cast 1 : u32) zero) "1")
      (string.eq (format.format "{0:.1$?}" (cast 1 : u64) one) "1")
      (string.eq (format.format "{0:.1$?}" (cast 1.5 : f32) zero) "2")
      (string.eq (format.format "{0:.1$?}" (cast 1.25 : f64) one) "1.2")
      (string.eq (format.format "{0:>20.1$?}" "a\n" zero) "\"a\\n\"")
      (string.eq (format.format "{0:>20.1$?}" '\n' one) "'\\n'")
      (string.eq pointer-precision "0x0"))))

(define (debug-reference-and-evaluation-ok?) : bool
  (let
    [state : DebugEvalState (DebugEvalState 0)]
    [value : i16 -42]
    [counted : String
      (format.format "{:x?}" (debug-counted (&mut state) value))]
    [shared : String (debug-shared-i16 (& value))]
    [mutable : String (debug-mutable-i16 (&mut value))]
    (and
      (string.eq counted "ffd6")
      (string.eq shared "-42")
      (string.eq mutable "FFD6")
      (= state.calls 1)
      (= value -42))))

(define (debug-reference-leaves-ok?) : bool
  (let
    [b : bool true]
    [i8v : i8 -1]
    [i16v : i16 -2]
    [i32v : i32 -3]
    [i64v : i64 -4]
    [u8v : u8 5]
    [u16v : u16 6]
    [u32v : u32 7]
    [u64v : u64 8]
    [f32v : f32 (cast 1.0 : f32)]
    [f64v : f64 (cast 2.0 : f64)]
    [c : char '\n']
    [text : String "r\n"]
    [slice : (& text str) (& text)]
    [shared-integers : String
      (format.format
        "{:x?}|{:X?}|{:?}|{:?}|{:?}|{:?}|{:?}|{:?}"
        (& i8v)
        (& i16v)
        (& i32v)
        (& i64v)
        (& u8v)
        (& u16v)
        (& u32v)
        (& u64v))]
    [shared-other : String
      (format.format
        "{:?}|{:?}|{:?}|{:?}|{:?}|{:?}"
        (& b)
        (& f32v)
        (& f64v)
        (& c)
        (& text)
        slice)]
    (and
      (string.eq shared-integers "ff|FFFE|-3|-4|5|6|7|8")
      (string.eq shared-other "true|1.0|2.0|'\\n'|\"r\\n\"|\"r\\n\"")
      b
      (= f64v (cast 2.0 : f64))
      (= (cast c : i64) 10))))

(define (debug-pointer-ok?) : bool
  (let
    [null : (Ptr i64) (ptr-null : (Ptr i64))]
    [plain : String
      (unsafe
        (format.format "{:?}" null))]
    [lower : String
      (unsafe
        (format.format "{:x?}" null))]
    [upper : String
      (unsafe
        (format.format "{:X?}" null))]
    [alternate : String
      (unsafe
        (format.format "{:#?}" null))]
    [shared : String (debug-shared-pointer (& null))]
    [mutable : String (debug-mutable-pointer (&mut null))]
    (and
      (string.eq plain "0x0")
      (string.eq lower plain)
      (string.eq upper plain)
      (string.eq alternate "0x0000000000000000")
      (string.eq shared plain)
      (string.eq mutable plain))))

(define (debug-arguments-ok?) : bool
  (let
    [arguments (format.args "inner={:x}" (cast 42 : i64))]
    [nested-arguments (format.args "outer=[{:X?}]" arguments)]
    [ordinary : String (format.format "{:?}" arguments)]
    [outer-options : String (format.format "{:+#20.0X?}" arguments)]
    [lower : String (format.format "{:x?}" arguments)]
    [pretty : String (format.format "{:#?}" arguments)]
    [nested : String (format.format "{:?}" nested-arguments)]
    [literal-rvalue : String (format.format "{:?}" (format.args "literal"))]
    [value-rvalue : String
      (format.format "{:X?}" (format.args "value={:#x?}" (cast -1 : i8)))]
    (and
      (string.eq ordinary "inner=2a")
      (string.eq outer-options ordinary)
      (string.eq lower ordinary)
      (string.eq pretty ordinary)
      (string.eq nested "outer=[inner=2a]")
      (string.eq literal-rvalue "literal")
      (string.eq value-rvalue "value=0xff"))))

(define (main) : i64
  (cond
    [(not (debug-options-abi-ok?)) 1]
    [(not (debug-integer-ok?)) 2]
    [(not (debug-integer-boundaries-ok?)) 3]
    [(not (debug-text-and-leaf-ok?)) 4]
    [(not (debug-float-ok?)) 5]
    [(not (debug-precision-matrix-ok?)) 6]
    [(not (debug-reference-and-evaluation-ok?)) 7]
    [(not (debug-reference-leaves-ok?)) 8]
    [(not (debug-pointer-ok?)) 9]
    [(not (debug-arguments-ok?)) 10]
    [else 42]))