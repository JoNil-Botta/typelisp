(import stdlib.comptime)

;; Exercise interpreted CTFE and the native macro image's Expr.Int data path.
(defmacro (integer-data-roundtrip [value : Expr]) : Expr
  (match value
    [(comptime.Expr.Int bits) (comptime.expr-int bits)]
    [_ (comptime.expr-int 0)]))

;; Preserve source spelling through quote/unquote before contextual lowering.
(defmacro (integer-expr-roundtrip [value : Expr]) : Expr
  `(ann ,value : i64))

(define i8-max-dec : i8
  127)
(define i8-max-hex : i8
  0x7f)
(define i8-max-bin : i8
  0b1111111)
(define i8-min-dec : i8
  -128)
(define i8-min-hex : i8
  -0x80)
(define i8-min-bin : i8
  -0b10000000)
(define i16-max-dec : i16
  32767)
(define i16-max-hex : i16
  0x7fff)
(define i16-max-bin : i16
  0b111111111111111)
(define i16-min-dec : i16
  -32768)
(define i16-min-hex : i16
  -0x8000)
(define i16-min-bin : i16
  -0b1000000000000000)
(define i32-max-dec : i32
  2147483647)
(define i32-max-hex : i32
  0x7fffffff)
(define i32-max-bin : i32
  0b1111111111111111111111111111111)
(define i32-min-dec : i32
  -2147483648)
(define i32-min-hex : i32
  -0x80000000)
(define i32-min-bin : i32
  -0b10000000000000000000000000000000)
(define i64-max-dec : i64
  9223372036854775807)
(define i64-max-hex : i64
  0x7fffffffffffffff)
(define i64-max-bin : i64
  0b111111111111111111111111111111111111111111111111111111111111111)
(define i64-min-dec : i64
  -9223372036854775808)
(define i64-min-hex : i64
  -0x8000000000000000)
(define i64-min-bin : i64
  -0b1000000000000000000000000000000000000000000000000000000000000000)
(define u8-max-dec : u8
  255)
(define u8-max-hex : u8
  0xff)
(define u8-max-bin : u8
  0b11111111)
(define u16-max-dec : u16
  65535)
(define u16-max-hex : u16
  0xffff)
(define u16-max-bin : u16
  0b1111111111111111)
(define u32-max-dec : u32
  4294967295)
(define u32-max-hex : u32
  0xffffffff)
(define u32-max-bin : u32
  0b11111111111111111111111111111111)
(define u64-max-dec : u64
  18446744073709551615)
(define u64-max-hex : u64
  0xffffffffffffffff)
(define u64-max-bin : u64
  0b1111111111111111111111111111111111111111111111111111111111111111)

(define (signed-boundaries-ok?) : bool
  (and
    (= i8-max-dec (bit-not (cast -128 : i8)))
    (= i8-max-dec i8-max-hex)
    (= i8-max-dec i8-max-bin)
    (= i8-min-dec -128)
    (= i8-min-dec i8-min-hex)
    (= i8-min-dec i8-min-bin)
    (= i16-max-dec (bit-not (cast -32768 : i16)))
    (= i16-max-dec i16-max-hex)
    (= i16-max-dec i16-max-bin)
    (= i16-min-dec -32768)
    (= i16-min-dec i16-min-hex)
    (= i16-min-dec i16-min-bin)
    (= i32-max-dec (bit-not (cast -2147483648 : i32)))
    (= i32-max-dec i32-max-hex)
    (= i32-max-dec i32-max-bin)
    (= i32-min-dec -2147483648)
    (= i32-min-dec i32-min-hex)
    (= i32-min-dec i32-min-bin)
    (= i64-max-dec (cast (shr (bit-not (cast 0 : u64)) (cast 1 : u64)) : i64))
    (= i64-max-dec i64-max-hex)
    (= i64-max-dec i64-max-bin)
    (= i64-min-dec (cast (shl (cast 1 : u64) (cast 63 : u64)) : i64))
    (= i64-min-dec i64-min-hex)
    (= i64-min-dec i64-min-bin)))

(define (unsigned-boundaries-ok?) : bool
  (and
    (= u8-max-dec (bit-not (cast 0 : u8)))
    (= u8-max-dec u8-max-hex)
    (= u8-max-dec u8-max-bin)
    (= u16-max-dec (bit-not (cast 0 : u16)))
    (= u16-max-dec u16-max-hex)
    (= u16-max-dec u16-max-bin)
    (= u32-max-dec (bit-not (cast 0 : u32)))
    (= u32-max-dec u32-max-hex)
    (= u32-max-dec u32-max-bin)
    (= u64-max-dec (bit-not (cast 0 : u64)))
    (= u64-max-dec u64-max-hex)
    (= u64-max-dec u64-max-bin)))

(define (comptime-boundaries-ok?) : bool
  (and
    (= (integer-data-roundtrip 9223372036854775807) i64-max-dec)
    (= (integer-expr-roundtrip 0x7fffffffffffffff) i64-max-dec)
    (= (comptime 9223372036854775807) i64-max-dec)))

(define (main) : i64
  (cond
    [(not (signed-boundaries-ok?)) 1]
    [(not (unsigned-boundaries-ok?)) 2]
    [(not (comptime-boundaries-ok?)) 3]
    [else 42]))