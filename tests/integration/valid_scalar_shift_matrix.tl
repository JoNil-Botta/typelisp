;; Runtime-variable scalar shifts across every integer width and signedness.
;; Keeping each operation in an out-of-line parameterized function prevents
;; constant folding from masking backend count guards and mnemonics.
(import stdlib.io)

(define (shl-i8 [value : i8] [count : i8]) : i8
  (shl value count))

(define (shr-i8 [value : i8] [count : i8]) : i8
  (shr value count))

(define (shl-u8 [value : u8] [count : u8]) : u8
  (shl value count))

(define (shr-u8 [value : u8] [count : u8]) : u8
  (shr value count))

(define (shl-i16 [value : i16] [count : i16]) : i16
  (shl value count))

(define (shr-i16 [value : i16] [count : i16]) : i16
  (shr value count))

(define (shl-u16 [value : u16] [count : u16]) : u16
  (shl value count))

(define (shr-u16 [value : u16] [count : u16]) : u16
  (shr value count))

(define (shl-i32 [value : i32] [count : i32]) : i32
  (shl value count))

(define (shr-i32 [value : i32] [count : i32]) : i32
  (shr value count))

(define (shl-u32 [value : u32] [count : u32]) : u32
  (shl value count))

(define (shr-u32 [value : u32] [count : u32]) : u32
  (shr value count))

(define (shl-i64 [value : i64] [count : i64]) : i64
  (shl value count))

(define (shr-i64 [value : i64] [count : i64]) : i64
  (shr value count))

(define (shl-u64 [value : u64] [count : u64]) : u64
  (shl value count))

(define (shr-u64 [value : u64] [count : u64]) : u64
  (shr value count))

(define (main) : i64
  (let
    ;; The process argc is runtime state, and the manifest invokes this file
    ;; with one argument (the executable), so every count below is the valid
    ;; value one without becoming a compile-time constant.
    [count : i64 (io.arg-count)]
    (if (and
      (= (cast (shl-i8 3 (cast count : i8)) : i64) 6)
      (= (cast (shr-i8 -4 (cast count : i8)) : i64) -2)
      (= (cast (shl-u8 3 (cast count : u8)) : i64) 6)
      (= (cast (shr-u8 252 (cast count : u8)) : i64) 126)
      (= (cast (shl-i16 3 (cast count : i16)) : i64) 6)
      (= (cast (shr-i16 -4 (cast count : i16)) : i64) -2)
      (= (cast (shl-u16 3 (cast count : u16)) : i64) 6)
      (= (cast (shr-u16 65532 (cast count : u16)) : i64) 32766)
      (= (cast (shl-i32 3 (cast count : i32)) : i64) 6)
      (= (cast (shr-i32 -4 (cast count : i32)) : i64) -2)
      (= (cast (shl-u32 3 (cast count : u32)) : i64) 6)
      (= (cast (shr-u32 4294967292 (cast count : u32)) : i64) 2147483646)
      (= (shl-i64 3 count) 6)
      (= (shr-i64 -4 count) -2)
      (= (cast (shl-u64 3 (cast count : u64)) : i64) 6)
      (=
        (cast (shr-u64 18446744073709551612 (cast count : u64)) : i64)
        9223372036854775806))
      42
      1)))