(import stdlib.format)
(import stdlib.string)

(defstruct RadixEvalState
  (calls i64))

(define (radix-counted [state : (&mut state RadixEvalState)] [value : i8]) : i8
  (begin
    (set! state.calls (+ state.calls 1))
    value))

(define (radix-row-ok?
  [binary : String]
  [octal : String]
  [lower : String]
  [upper : String]
  [expected-binary : String]
  [expected-octal : String]
  [expected-lower : String]
  [expected-upper : String]) : bool
  (and
    (string.eq binary expected-binary)
    (string.eq octal expected-octal)
    (string.eq lower expected-lower)
    (string.eq upper expected-upper)))

(define (signed-radix-table-ok?) : bool
  (and
    (radix-row-ok?
      (format.format "{:b}" (cast 0 : i8))
      (format.format "{:o}" (cast 0 : i8))
      (format.format "{:x}" (cast 0 : i8))
      (format.format "{:X}" (cast 0 : i8))
      "0"
      "0"
      "0"
      "0")
    (radix-row-ok?
      (format.format "{:b}" (cast 1 : i8))
      (format.format "{:o}" (cast 1 : i8))
      (format.format "{:x}" (cast 1 : i8))
      (format.format "{:X}" (cast 1 : i8))
      "1"
      "1"
      "1"
      "1")
    (radix-row-ok?
      (format.format "{:b}" (cast -1 : i8))
      (format.format "{:o}" (cast -1 : i8))
      (format.format "{:x}" (cast -1 : i8))
      (format.format "{:X}" (cast -1 : i8))
      "11111111"
      "377"
      "ff"
      "FF")
    (radix-row-ok?
      (format.format "{:b}" (cast -128 : i8))
      (format.format "{:o}" (cast -128 : i8))
      (format.format "{:x}" (cast -128 : i8))
      (format.format "{:X}" (cast -128 : i8))
      "10000000"
      "200"
      "80"
      "80")
    (radix-row-ok?
      (format.format "{:b}" (cast 127 : i8))
      (format.format "{:o}" (cast 127 : i8))
      (format.format "{:x}" (cast 127 : i8))
      (format.format "{:X}" (cast 127 : i8))
      "1111111"
      "177"
      "7f"
      "7F")
    (radix-row-ok?
      (format.format "{:b}" (cast 64 : i8))
      (format.format "{:o}" (cast 64 : i8))
      (format.format "{:x}" (cast 64 : i8))
      (format.format "{:X}" (cast 64 : i8))
      "1000000"
      "100"
      "40"
      "40")
    (radix-row-ok?
      (format.format "{:b}" (cast 0 : i16))
      (format.format "{:o}" (cast 0 : i16))
      (format.format "{:x}" (cast 0 : i16))
      (format.format "{:X}" (cast 0 : i16))
      "0"
      "0"
      "0"
      "0")
    (radix-row-ok?
      (format.format "{:b}" (cast 1 : i16))
      (format.format "{:o}" (cast 1 : i16))
      (format.format "{:x}" (cast 1 : i16))
      (format.format "{:X}" (cast 1 : i16))
      "1"
      "1"
      "1"
      "1")
    (radix-row-ok?
      (format.format "{:b}" (cast -1 : i16))
      (format.format "{:o}" (cast -1 : i16))
      (format.format "{:x}" (cast -1 : i16))
      (format.format "{:X}" (cast -1 : i16))
      "1111111111111111"
      "177777"
      "ffff"
      "FFFF")
    (radix-row-ok?
      (format.format "{:b}" (cast -32768 : i16))
      (format.format "{:o}" (cast -32768 : i16))
      (format.format "{:x}" (cast -32768 : i16))
      (format.format "{:X}" (cast -32768 : i16))
      "1000000000000000"
      "100000"
      "8000"
      "8000")
    (radix-row-ok?
      (format.format "{:b}" (cast 32767 : i16))
      (format.format "{:o}" (cast 32767 : i16))
      (format.format "{:x}" (cast 32767 : i16))
      (format.format "{:X}" (cast 32767 : i16))
      "111111111111111"
      "77777"
      "7fff"
      "7FFF")
    (radix-row-ok?
      (format.format "{:b}" (cast 16384 : i16))
      (format.format "{:o}" (cast 16384 : i16))
      (format.format "{:x}" (cast 16384 : i16))
      (format.format "{:X}" (cast 16384 : i16))
      "100000000000000"
      "40000"
      "4000"
      "4000")
    (radix-row-ok?
      (format.format "{:b}" (cast 0 : i32))
      (format.format "{:o}" (cast 0 : i32))
      (format.format "{:x}" (cast 0 : i32))
      (format.format "{:X}" (cast 0 : i32))
      "0"
      "0"
      "0"
      "0")
    (radix-row-ok?
      (format.format "{:b}" (cast 1 : i32))
      (format.format "{:o}" (cast 1 : i32))
      (format.format "{:x}" (cast 1 : i32))
      (format.format "{:X}" (cast 1 : i32))
      "1"
      "1"
      "1"
      "1")
    (radix-row-ok?
      (format.format "{:b}" (cast -1 : i32))
      (format.format "{:o}" (cast -1 : i32))
      (format.format "{:x}" (cast -1 : i32))
      (format.format "{:X}" (cast -1 : i32))
      "11111111111111111111111111111111"
      "37777777777"
      "ffffffff"
      "FFFFFFFF")
    (radix-row-ok?
      (format.format "{:b}" (cast -2147483648 : i32))
      (format.format "{:o}" (cast -2147483648 : i32))
      (format.format "{:x}" (cast -2147483648 : i32))
      (format.format "{:X}" (cast -2147483648 : i32))
      "10000000000000000000000000000000"
      "20000000000"
      "80000000"
      "80000000")
    (radix-row-ok?
      (format.format "{:b}" (cast 2147483647 : i32))
      (format.format "{:o}" (cast 2147483647 : i32))
      (format.format "{:x}" (cast 2147483647 : i32))
      (format.format "{:X}" (cast 2147483647 : i32))
      "1111111111111111111111111111111"
      "17777777777"
      "7fffffff"
      "7FFFFFFF")
    (radix-row-ok?
      (format.format "{:b}" (cast 1073741824 : i32))
      (format.format "{:o}" (cast 1073741824 : i32))
      (format.format "{:x}" (cast 1073741824 : i32))
      (format.format "{:X}" (cast 1073741824 : i32))
      "1000000000000000000000000000000"
      "10000000000"
      "40000000"
      "40000000")
    (radix-row-ok?
      (format.format "{:b}" (cast 0 : i64))
      (format.format "{:o}" (cast 0 : i64))
      (format.format "{:x}" (cast 0 : i64))
      (format.format "{:X}" (cast 0 : i64))
      "0"
      "0"
      "0"
      "0")
    (radix-row-ok?
      (format.format "{:b}" (cast 1 : i64))
      (format.format "{:o}" (cast 1 : i64))
      (format.format "{:x}" (cast 1 : i64))
      (format.format "{:X}" (cast 1 : i64))
      "1"
      "1"
      "1"
      "1")
    (radix-row-ok?
      (format.format "{:b}" (cast -1 : i64))
      (format.format "{:o}" (cast -1 : i64))
      (format.format "{:x}" (cast -1 : i64))
      (format.format "{:X}" (cast -1 : i64))
      "1111111111111111111111111111111111111111111111111111111111111111"
      "1777777777777777777777"
      "ffffffffffffffff"
      "FFFFFFFFFFFFFFFF")
    (radix-row-ok?
      (format.format "{:b}" (cast -9223372036854775808 : i64))
      (format.format "{:o}" (cast -9223372036854775808 : i64))
      (format.format "{:x}" (cast -9223372036854775808 : i64))
      (format.format "{:X}" (cast -9223372036854775808 : i64))
      "1000000000000000000000000000000000000000000000000000000000000000"
      "1000000000000000000000"
      "8000000000000000"
      "8000000000000000")
    (radix-row-ok?
      (format.format "{:b}" (cast 9223372036854775807 : i64))
      (format.format "{:o}" (cast 9223372036854775807 : i64))
      (format.format "{:x}" (cast 9223372036854775807 : i64))
      (format.format "{:X}" (cast 9223372036854775807 : i64))
      "111111111111111111111111111111111111111111111111111111111111111"
      "777777777777777777777"
      "7fffffffffffffff"
      "7FFFFFFFFFFFFFFF")
    (radix-row-ok?
      (format.format "{:b}" (cast 4611686018427387904 : i64))
      (format.format "{:o}" (cast 4611686018427387904 : i64))
      (format.format "{:x}" (cast 4611686018427387904 : i64))
      (format.format "{:X}" (cast 4611686018427387904 : i64))
      "100000000000000000000000000000000000000000000000000000000000000"
      "400000000000000000000"
      "4000000000000000"
      "4000000000000000")))

(define (unsigned-radix-table-ok?) : bool
  (and
    (radix-row-ok?
      (format.format "{:b}" (cast 0 : u8))
      (format.format "{:o}" (cast 0 : u8))
      (format.format "{:x}" (cast 0 : u8))
      (format.format "{:X}" (cast 0 : u8))
      "0"
      "0"
      "0"
      "0")
    (radix-row-ok?
      (format.format "{:b}" (cast 1 : u8))
      (format.format "{:o}" (cast 1 : u8))
      (format.format "{:x}" (cast 1 : u8))
      (format.format "{:X}" (cast 1 : u8))
      "1"
      "1"
      "1"
      "1")
    (radix-row-ok?
      (format.format "{:b}" (cast 255 : u8))
      (format.format "{:o}" (cast 255 : u8))
      (format.format "{:x}" (cast 255 : u8))
      (format.format "{:X}" (cast 255 : u8))
      "11111111"
      "377"
      "ff"
      "FF")
    (radix-row-ok?
      (format.format "{:b}" (cast 128 : u8))
      (format.format "{:o}" (cast 128 : u8))
      (format.format "{:x}" (cast 128 : u8))
      (format.format "{:X}" (cast 128 : u8))
      "10000000"
      "200"
      "80"
      "80")
    (radix-row-ok?
      (format.format "{:b}" (cast 0 : u16))
      (format.format "{:o}" (cast 0 : u16))
      (format.format "{:x}" (cast 0 : u16))
      (format.format "{:X}" (cast 0 : u16))
      "0"
      "0"
      "0"
      "0")
    (radix-row-ok?
      (format.format "{:b}" (cast 1 : u16))
      (format.format "{:o}" (cast 1 : u16))
      (format.format "{:x}" (cast 1 : u16))
      (format.format "{:X}" (cast 1 : u16))
      "1"
      "1"
      "1"
      "1")
    (radix-row-ok?
      (format.format "{:b}" (cast 65535 : u16))
      (format.format "{:o}" (cast 65535 : u16))
      (format.format "{:x}" (cast 65535 : u16))
      (format.format "{:X}" (cast 65535 : u16))
      "1111111111111111"
      "177777"
      "ffff"
      "FFFF")
    (radix-row-ok?
      (format.format "{:b}" (cast 32768 : u16))
      (format.format "{:o}" (cast 32768 : u16))
      (format.format "{:x}" (cast 32768 : u16))
      (format.format "{:X}" (cast 32768 : u16))
      "1000000000000000"
      "100000"
      "8000"
      "8000")
    (radix-row-ok?
      (format.format "{:b}" (cast 0 : u32))
      (format.format "{:o}" (cast 0 : u32))
      (format.format "{:x}" (cast 0 : u32))
      (format.format "{:X}" (cast 0 : u32))
      "0"
      "0"
      "0"
      "0")
    (radix-row-ok?
      (format.format "{:b}" (cast 1 : u32))
      (format.format "{:o}" (cast 1 : u32))
      (format.format "{:x}" (cast 1 : u32))
      (format.format "{:X}" (cast 1 : u32))
      "1"
      "1"
      "1"
      "1")
    (radix-row-ok?
      (format.format "{:b}" (cast 4294967295 : u32))
      (format.format "{:o}" (cast 4294967295 : u32))
      (format.format "{:x}" (cast 4294967295 : u32))
      (format.format "{:X}" (cast 4294967295 : u32))
      "11111111111111111111111111111111"
      "37777777777"
      "ffffffff"
      "FFFFFFFF")
    (radix-row-ok?
      (format.format "{:b}" (cast 2147483648 : u32))
      (format.format "{:o}" (cast 2147483648 : u32))
      (format.format "{:x}" (cast 2147483648 : u32))
      (format.format "{:X}" (cast 2147483648 : u32))
      "10000000000000000000000000000000"
      "20000000000"
      "80000000"
      "80000000")
    (radix-row-ok?
      (format.format "{:b}" (cast 0 : u64))
      (format.format "{:o}" (cast 0 : u64))
      (format.format "{:x}" (cast 0 : u64))
      (format.format "{:X}" (cast 0 : u64))
      "0"
      "0"
      "0"
      "0")
    (radix-row-ok?
      (format.format "{:b}" (cast 1 : u64))
      (format.format "{:o}" (cast 1 : u64))
      (format.format "{:x}" (cast 1 : u64))
      (format.format "{:X}" (cast 1 : u64))
      "1"
      "1"
      "1"
      "1")
    (radix-row-ok?
      (format.format "{:b}" (cast 18446744073709551615 : u64))
      (format.format "{:o}" (cast 18446744073709551615 : u64))
      (format.format "{:x}" (cast 18446744073709551615 : u64))
      (format.format "{:X}" (cast 18446744073709551615 : u64))
      "1111111111111111111111111111111111111111111111111111111111111111"
      "1777777777777777777777"
      "ffffffffffffffff"
      "FFFFFFFFFFFFFFFF")
    (radix-row-ok?
      (format.format "{:b}" (cast 9223372036854775808 : u64))
      (format.format "{:o}" (cast 9223372036854775808 : u64))
      (format.format "{:x}" (cast 9223372036854775808 : u64))
      (format.format "{:X}" (cast 9223372036854775808 : u64))
      "1000000000000000000000000000000000000000000000000000000000000000"
      "1000000000000000000000"
      "8000000000000000"
      "8000000000000000")))

(define (radix-options-ok?) : bool
  (let
    [borrowed-owner : i16 (cast -1 : i16)]
    [borrowed : (& borrowed-owner i16) (& borrowed-owner)]
    [width : i64 10]
    [state : RadixEvalState (RadixEvalState 0)]
    [repeated : String
      (format.format "{0:x}/{0:X}" (radix-counted (&mut state) (cast -1 : i8)))]
    (and
      (string.eq (format.format "{:#b}" (cast 5 : u8)) "0b101")
      (string.eq (format.format "{:#o}" (cast 9 : u8)) "0o11")
      (string.eq (format.format "{:#x}" (cast 255 : u8)) "0xff")
      (string.eq (format.format "{:#X}" (cast 255 : u8)) "0xFF")
      (string.eq (format.format "{:#x}" (cast 0 : u8)) "0x0")
      (string.eq (format.format "{:+x}" (cast -1 : i8)) "+ff")
      (string.eq (format.format "{:+#010x}" (cast -1 : i8)) "+0x00000ff")
      (string.eq (format.format "{:#010x}" (cast -1 : i8)) "0x000000ff")
      (string.eq (format.format "{:#010X}" (cast -1 : i8)) "0x000000FF")
      (string.eq (format.format "{:#010b}" (cast -1 : i8)) "0b11111111")
      (string.eq (format.format "{:#010o}" (cast -1 : i8)) "0o00000377")
      (string.eq (format.format "{:*^#12x}" (cast 42 : u8)) "****0x2a****")
      (string.eq (format.format "{0:#01$x}" (cast 42 : u8) width) "0x0000002a")
      (string.eq (format.format "{1:0$x}" width (cast 42 : u8)) "        2a")
      (string.eq
        (format.format "{value:#010X}" (format.named value (cast 42 : u8)))
        "0x0000002A")
      (string.eq (format.format "{:.1x}" (cast 291 : u16)) "123")
      (string.eq (format.format "{:x}" borrowed) "ffff")
      (string.eq repeated "ff/FF")
      (= state.calls 1))))

(define (main) : i64
  (cond
    [(not (signed-radix-table-ok?)) 1]
    [(not (unsigned-radix-table-ok?)) 2]
    [(not (radix-options-ok?)) 3]
    [else 42]))