;# LEB128 variable-length integers.
;#
;# DWARF, `.eh_frame` and other binary formats store integers as little-endian
;# base-128 groups: seven value bits per byte, with the high bit set on every
;# byte except the last. This module owns that encoding once. `decode-unsigned`
;# and `decode-signed` read one integer from `bytes[offset, end)`,
;# `unsigned-size` and `signed-size` measure an encoding, and `push-unsigned!`
;# and `push-signed!` append the minimal one.
;#
;# Values are 64 bits wide. An unsigned value travels as its `i64` bit pattern,
;# so values from 2^63 up read back negative, like `byte_le.read-u64`. A decode
;# accepts any encoding of at most `max-length` bytes, including padded
;# (non-minimal) ones, and fails on an encoding that runs past `end`, that is
;# longer, or whose value does not fit in 64 bits. A caller with a narrower
;# admitted range checks the decoded value and length itself.
;#
;# Decoding never allocates. `push-*!` grows the builder in the active arena
;# when it is full.
;#
;# Usage: `(import stdlib.leb128)`
;#
;# ```typelisp
;# (import stdlib.byte_buf_core)
;# (import stdlib.leb128)
;# (define (main) : i64
;#   (let
;#     [out : byte_buf_core.ByteBufBuilder (byte_buf_core.byte-buf-builder-new)]
;#     (begin
;#       (leb128.push-unsigned! (&mut out) 624485)
;#       (let
;#         [bytes : (__tl_dyn-array u8)
;#           (byte_buf_core.byte-buf-builder-finish-array (& out))]
;#         (leb128.decode-unsigned (& bytes) 0 (array-length bytes)).value))))
;# ```
(import stdlib.byte_buf_core)
(cfg test (import stdlib.test))

;: The longest encoding of a 64-bit value, in bytes.
(define max-length : i64
  10)

;: One decoded integer. `value` is the 64-bit value (an unsigned one as its
;: `i64` bit pattern) and `next` the offset just past the encoding. On failure
;: `ok?` is false, `value` is 0 and `next` is where decoding stopped.
(defstruct Decoded
  (ok? bool)
  (value i64)
  (next i64))

;: `value` shifted right by 7 bits as an unsigned 64-bit pattern.
(define (leb128-shift-unsigned [value : i64]) : i64
  (bit-and (shr value 7) 144115188075855871))

;: Decode the unsigned LEB128 integer at `bytes[offset, end)`.
(define (decode-unsigned
  [bytes : (& bytes (__tl_dyn-array u8))]
  [offset : i64]
  [end : i64]) : Decoded
  (if (and (< offset end) (< (cast (array-ref bytes offset) : i64) 128))
    ;; Most operands fit one byte.
    (Decoded true (cast (array-ref bytes offset) : i64) (+ offset 1))
    (decode-unsigned-groups bytes offset end)))

;: `decode-unsigned` for an encoding of more than one byte, or none.
(define (decode-unsigned-groups
  [bytes : (& bytes (__tl_dyn-array u8))]
  [offset : i64]
  [end : i64]) : Decoded
  (let
    [value : i64 0]
    [shift : i64 0]
    [at : i64 offset]
    [done : bool false]
    [ok : bool true]
    (begin
      (while (and ok (not done))
        (if (or (>= at end) (>= (- at offset) max-length))
          (set! ok false)
          (let
            [byte : i64 (cast (array-ref bytes at) : i64)]
            [payload : i64 (bit-and byte 127)]
            (begin
              ;; The tenth group holds bit 63 only.
              (if (and (= shift 63) (> payload 1))
                (set! ok false)
                (set! value (bit-or value (shl payload shift))))
              (set! shift (+ shift 7))
              (set! at (+ at 1))
              (if (< byte 128)
                (set! done true)
                unit)))))
      (if ok
        (Decoded true value at)
        (Decoded false 0 at)))))

;: Decode the signed LEB128 integer at `bytes[offset, end)`.
(define (decode-signed
  [bytes : (& bytes (__tl_dyn-array u8))]
  [offset : i64]
  [end : i64]) : Decoded
  (if (and (< offset end) (< (cast (array-ref bytes offset) : i64) 128))
    (let
      [byte : i64 (cast (array-ref bytes offset) : i64)]
      (Decoded
        true
        (if (< byte 64)
          byte
          (- byte 128))
        (+ offset 1)))
    (decode-signed-groups bytes offset end)))

;: `decode-signed` for an encoding of more than one byte, or none.
(define (decode-signed-groups
  [bytes : (& bytes (__tl_dyn-array u8))]
  [offset : i64]
  [end : i64]) : Decoded
  (let
    [value : i64 0]
    [shift : i64 0]
    [at : i64 offset]
    [last : i64 0]
    [done : bool false]
    [ok : bool true]
    (begin
      (while (and ok (not done))
        (if (or (>= at end) (>= (- at offset) max-length))
          (set! ok false)
          (let
            [byte : i64 (cast (array-ref bytes at) : i64)]
            [payload : i64 (bit-and byte 127)]
            (begin
              ;; The tenth group holds bit 63, and its other six bits must
              ;; repeat it: only 0x00 and 0x7f end a 64-bit value there.
              (if (and (= shift 63) (not (or (= payload 0) (= payload 127))))
                (set! ok false)
                (set! value (bit-or value (shl payload shift))))
              (set! last byte)
              (set! shift (+ shift 7))
              (set! at (+ at 1))
              (if (< byte 128)
                (set! done true)
                unit)))))
      (cond
        [(not ok) (Decoded false 0 at)]
        [(and (< shift 64) (!= (bit-and last 64) 0))
          (Decoded true (bit-or value (shl -1 shift)) at)]
        [else (Decoded true value at)]))))

;: The length of the minimal unsigned encoding of `value` (a 64-bit pattern).
(define (unsigned-size [value : i64]) : i64
  (let
    [size : i64 1]
    [rest : i64 (leb128-shift-unsigned value)]
    (begin
      (while (!= rest 0)
        (begin
          (set! size (+ size 1))
          (set! rest (leb128-shift-unsigned rest))))
      size)))

;: The length of the minimal signed encoding of `value`.
(define (signed-size [value : i64]) : i64
  (let
    [size : i64 1]
    [rest : i64 value]
    [done : bool false]
    (begin
      (while (not done)
        (let
          [byte : i64 (bit-and rest 127)]
          [next : i64 (shr rest 7)]
          (if (or
            (and (= next 0) (= (bit-and byte 64) 0))
            (and (= next -1) (!= (bit-and byte 64) 0)))
            (set! done true)
            (begin
              (set! size (+ size 1))
              (set! rest next)))))
      size)))

;: Append the minimal unsigned encoding of `value` (a 64-bit pattern).
(define (push-unsigned!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [value : i64]) : unit
  (let
    [rest : i64 value]
    [done : bool false]
    (while (not done)
      (let
        [byte : i64 (bit-and rest 127)]
        (begin
          (set! rest (leb128-shift-unsigned rest))
          (if (= rest 0)
            (begin
              (byte_buf_core.byte-buf-builder-push out (cast byte : u8))
              (set! done true))
            (byte_buf_core.byte-buf-builder-push
              out
              (cast (bit-or byte 128) : u8))))))))

;: Append the minimal signed encoding of `value`.
(define (push-signed!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [value : i64]) : unit
  (let
    [rest : i64 value]
    [done : bool false]
    (while (not done)
      (let
        [byte : i64 (bit-and rest 127)]
        [next : i64 (shr rest 7)]
        (if (or
          (and (= next 0) (= (bit-and byte 64) 0))
          (and (= next -1) (!= (bit-and byte 64) 0)))
          (begin
            (byte_buf_core.byte-buf-builder-push out (cast byte : u8))
            (set! done true))
          (begin
            (byte_buf_core.byte-buf-builder-push
              out
              (cast (bit-or byte 128) : u8))
            (set! rest next)))))))

(cfg
  test
  (define (leb128-test-bytes [hex : (& hex str)]) : (__tl_dyn-array u8)
    (let
      [count : i64 (/ (string-length hex) 2)]
      [bytes : (__tl_dyn-array u8) (__tl_make-array u8 count)]
      [index : i64 0]
      (begin
        (while (< index count)
          (let
            [high : i64 (leb128-test-nibble hex (* index 2))]
            [low : i64 (leb128-test-nibble hex (+ (* index 2) 1))]
            (begin
              (set! (array-ref bytes index) (cast (+ (* high 16) low) : u8))
              (set! index (+ index 1)))))
        bytes))))

(cfg
  test
  (define (leb128-test-nibble [hex : (& hex str)] [index : i64]) : i64
    (let
      [c : i64 (cast (string-ref hex index) : i64)]
      (if (<= c 57)
        (- c 48)
        (- c 87)))))

(cfg
  test
  (define (leb128-test-decode [hex : (& hex str)] [signed? : bool]) : Decoded
    (let
      [bytes : (__tl_dyn-array u8) (leb128-test-bytes hex)]
      (if signed?
        (decode-signed (& bytes) 0 (array-length bytes))
        (decode-unsigned (& bytes) 0 (array-length bytes))))))

(cfg
  test
  (define (leb128-test-round-trip? [value : i64] [signed? : bool]) : bool
    (let
      [out : byte_buf_core.ByteBufBuilder (byte_buf_core.byte-buf-builder-new)]
      [_push : unit
        (if signed?
          (push-signed! (&mut out) value)
          (push-unsigned! (&mut out) value))]
      [bytes : (__tl_dyn-array u8)
        (byte_buf_core.byte-buf-builder-finish-array (& out))]
      [decoded : Decoded
        (if signed?
          (decode-signed (& bytes) 0 (array-length bytes))
          (decode-unsigned (& bytes) 0 (array-length bytes)))]
      (and
        decoded.ok?
        (= decoded.value value)
        (= decoded.next (array-length bytes))
        (=
          (array-length bytes)
          (if signed?
            (signed-size value)
            (unsigned-size value)))))))

(test
  leb128-decodes-dwarf-examples
  (begin
    (test.assert-i64-eq (leb128-test-decode "02" false).value 2 "2")
    (test.assert-i64-eq (leb128-test-decode "7f" false).value 127 "127")
    (test.assert-i64-eq (leb128-test-decode "8001" false).value 128 "128")
    (test.assert-i64-eq
      (leb128-test-decode "e58e26" false).value
      624485
      "624485")
    (test.assert-i64-eq (leb128-test-decode "7f" true).value -1 "-1")
    (test.assert-i64-eq (leb128-test-decode "807f" true).value -128 "-128")
    (test.assert-i64-eq
      (leb128-test-decode "c0bb78" true).value
      -123456
      "-123456")
    (test.assert-i64-eq (leb128-test-decode "3f" true).value 63 "63")
    (test.assert-i64-eq (leb128-test-decode "c000" true).value 64 "64")
    (test.assert-i64-eq (leb128-test-decode "e58e26ff" false).next 3 "next")))

(test
  leb128-accepts-64-bit-and-padded-encodings
  (begin
    (test.assert-i64-eq
      (leb128-test-decode "ffffffffffffffffff01" false).value
      -1
      "2^64-1 as its bit pattern")
    (test.assert-i64-eq
      (leb128-test-decode "80808080808080808001" false).value
      (shl 1 63)
      "2^63")
    (test.assert-i64-eq
      (leb128-test-decode "80808080808080808000" false).value
      0
      "ten-byte zero")
    (test.assert-i64-eq
      (leb128-test-decode "808000" false).value
      0
      "padded zero")
    (test.assert-i64-eq
      (leb128-test-decode "8080808080808080807f" true).value
      (shl -1 63)
      "-2^63")
    (test.assert-i64-eq
      (leb128-test-decode "ffffffffffffffffff00" true).value
      9223372036854775807
      "2^63-1")
    (test.assert-i64-eq (leb128-test-decode "ff7f" true).value -1 "padded -1")))

(test
  leb128-rejects-truncated-overlong-and-oversized
  (begin
    (test.assert-false (leb128-test-decode "" false).ok? "empty")
    (test.assert-false (leb128-test-decode "80" false).ok? "truncated")
    (test.assert-i64-eq (leb128-test-decode "8080" false).next 2 "stops at end")
    (test.assert-false
      (leb128-test-decode "ffffffffffffffffff02" false).ok?
      "unsigned 65th bit")
    (test.assert-false
      (leb128-test-decode "8080808080808080808000" false).ok?
      "eleven bytes")
    (test.assert-false
      (leb128-test-decode "80808080808080808040" true).ok?
      "signed tenth group that does not repeat bit 63")
    (test.assert-false
      (leb128-test-decode "ffffffffffffffffff01" true).ok?
      "signed tenth group 0x01")
    (test.assert-false
      (leb128-test-decode "8080808080808080808000" true).ok?
      "signed eleven bytes")))

(test
  leb128-round-trips-minimal-encodings
  (begin
    (test.assert-true (leb128-test-round-trip? 0 false) "unsigned 0")
    (test.assert-true (leb128-test-round-trip? 127 false) "unsigned 127")
    (test.assert-true (leb128-test-round-trip? 128 false) "unsigned 128")
    (test.assert-true
      (leb128-test-round-trip? 9223372036854775807 false)
      "unsigned 2^63-1")
    (test.assert-true (leb128-test-round-trip? -1 false) "unsigned 2^64-1")
    (test.assert-true
      (leb128-test-round-trip? (shl 1 63) false)
      "unsigned 2^63")
    (test.assert-i64-eq (unsigned-size -1) 10 "2^64-1 needs ten bytes")
    (test.assert-true (leb128-test-round-trip? 0 true) "signed 0")
    (test.assert-true (leb128-test-round-trip? 63 true) "signed 63")
    (test.assert-true (leb128-test-round-trip? 64 true) "signed 64")
    (test.assert-true (leb128-test-round-trip? -64 true) "signed -64")
    (test.assert-true (leb128-test-round-trip? -65 true) "signed -65")
    (test.assert-true
      (leb128-test-round-trip? 9223372036854775807 true)
      "signed 2^63-1")
    (test.assert-true (leb128-test-round-trip? (shl -1 63) true) "signed -2^63")
    (test.assert-i64-eq (signed-size (shl -1 63)) 10 "-2^63 needs ten bytes")))