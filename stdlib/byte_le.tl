;# Little-endian integer encoding over byte buffers.
;#
;# Binary formats written by the compiler (the `.tlci` container, frontend
;# surface sections, incremental identity transcripts, the embedded stdlib
;# envelope) store integers least significant byte first. This module owns that
;# byte order once: `push-*!` appends to a `byte_buf_core.ByteBufBuilder`,
;# `set-*!` overwrites bytes in place, and `read-*` decodes them. Values travel
;# as `i64`; a 16- or 32-bit field takes the low bits on write and reads back
;# zero-extended, and a 64-bit field round-trips every `i64` bit pattern.
;#
;# Like `byte_buf_core`, this is an internal compiler/runtime core: it spells
;# byte storage as `__tl_dyn-array u8`. Reads and in-place writes index that
;# storage with ordinary bounds checks, so a caller that has not proved the
;# field lies inside the buffer traps instead of reading past it. `push-*!`
;# grows the builder in the active arena when it is full; `read-*` and `set-*!`
;# never allocate.
;#
;# Usage: `(import stdlib.byte_le)`
;#
;# ```typelisp
;# (import stdlib.byte_buf_core)
;# (import stdlib.byte_le)
;# (define (main) : i64
;#   (let
;#     [out : byte_buf_core.ByteBufBuilder (byte_buf_core.byte-buf-builder-new)]
;#     (begin
;#       (byte_le.push-u32! (&mut out) 305419896)
;#       (let
;#         [bytes : (__tl_dyn-array u8)
;#           (byte_buf_core.byte-buf-builder-finish-array (& out))]
;#         (byte_le.read-u32 (& bytes) 0)))))
;# ```
(import stdlib.byte_buf_core)
(cfg test (import stdlib.test))

;: The byte of `value` at bit position `shift` (a multiple of 8).
(define (byte-le-byte [value : i64] [shift : i64]) : u8
  (cast (bit-and (shr value shift) 255) : u8))

;: The zero-extended byte at `bytes[offset]`.
(define (byte-le-at [bytes : (& bytes (__tl_dyn-array u8))] [offset : i64]) : i64
  (cast (array-ref bytes offset) : i64))

;: Append the low 16 bits of `value`, least significant byte first.
(define (push-u16!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [value : i64]) : unit
  (begin
    (byte_buf_core.byte-buf-builder-push out (byte-le-byte value 0))
    (byte_buf_core.byte-buf-builder-push out (byte-le-byte value 8))))

;: Append the low 32 bits of `value`, least significant byte first.
(define (push-u32!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [value : i64]) : unit
  (begin
    (push-u16! out value)
    (push-u16! out (shr value 16))))

;: Append all 64 bits of `value`, least significant byte first.
(define (push-u64!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [value : i64]) : unit
  (begin
    (byte_buf_core.byte-buf-builder-push out (byte-le-byte value 0))
    (byte_buf_core.byte-buf-builder-push out (byte-le-byte value 8))
    (byte_buf_core.byte-buf-builder-push out (byte-le-byte value 16))
    (byte_buf_core.byte-buf-builder-push out (byte-le-byte value 24))
    (byte_buf_core.byte-buf-builder-push out (byte-le-byte value 32))
    (byte_buf_core.byte-buf-builder-push out (byte-le-byte value 40))
    (byte_buf_core.byte-buf-builder-push out (byte-le-byte value 48))
    (byte_buf_core.byte-buf-builder-push out (byte-le-byte value 56))))

;: Overwrite `bytes[offset..offset+2)` with the low 16 bits of `value`.
(define (set-u16!
  [bytes : (&mut bytes (__tl_dyn-array u8))]
  [offset : i64]
  [value : i64]) : unit
  (begin
    (set! (array-ref bytes offset) (byte-le-byte value 0))
    (set! (array-ref bytes (+ offset 1)) (byte-le-byte value 8))))

;: Overwrite `bytes[offset..offset+4)` with the low 32 bits of `value`.
(define (set-u32!
  [bytes : (&mut bytes (__tl_dyn-array u8))]
  [offset : i64]
  [value : i64]) : unit
  (begin
    (set-u16! bytes offset value)
    (set-u16! bytes (+ offset 2) (shr value 16))))

;: Overwrite `bytes[offset..offset+8)` with all 64 bits of `value`.
(define (set-u64!
  [bytes : (&mut bytes (__tl_dyn-array u8))]
  [offset : i64]
  [value : i64]) : unit
  (begin
    (set! (array-ref bytes offset) (byte-le-byte value 0))
    (set! (array-ref bytes (+ offset 1)) (byte-le-byte value 8))
    (set! (array-ref bytes (+ offset 2)) (byte-le-byte value 16))
    (set! (array-ref bytes (+ offset 3)) (byte-le-byte value 24))
    (set! (array-ref bytes (+ offset 4)) (byte-le-byte value 32))
    (set! (array-ref bytes (+ offset 5)) (byte-le-byte value 40))
    (set! (array-ref bytes (+ offset 6)) (byte-le-byte value 48))
    (set! (array-ref bytes (+ offset 7)) (byte-le-byte value 56))))

;: Read the zero-extended 16-bit value stored at `bytes[offset..offset+2)`.
(define (read-u16 [bytes : (& bytes (__tl_dyn-array u8))] [offset : i64]) : i64
  (bit-or (byte-le-at bytes offset) (shl (byte-le-at bytes (+ offset 1)) 8)))

;: Read the zero-extended 32-bit value stored at `bytes[offset..offset+4)`.
(define (read-u32 [bytes : (& bytes (__tl_dyn-array u8))] [offset : i64]) : i64
  (bit-or (read-u16 bytes offset) (shl (read-u16 bytes (+ offset 2)) 16)))

;: Read the 64-bit pattern stored at `bytes[offset..offset+8)` as an `i64`.
(define (read-u64 [bytes : (& bytes (__tl_dyn-array u8))] [offset : i64]) : i64
  (bit-or
    (bit-or
      (bit-or (byte-le-at bytes offset) (shl (byte-le-at bytes (+ offset 1)) 8))
      (bit-or
        (shl (byte-le-at bytes (+ offset 2)) 16)
        (shl (byte-le-at bytes (+ offset 3)) 24)))
    (bit-or
      (bit-or
        (shl (byte-le-at bytes (+ offset 4)) 32)
        (shl (byte-le-at bytes (+ offset 5)) 40))
      (bit-or
        (shl (byte-le-at bytes (+ offset 6)) 48)
        (shl (byte-le-at bytes (+ offset 7)) 56)))))

(test
  byte-le-push-read-round-trip
  (let
    [out : byte_buf_core.ByteBufBuilder
      (byte_buf_core.byte-buf-builder-with-capacity 1)]
    (begin
      (push-u16! (&mut out) 65244)
      (push-u32! (&mut out) 4294967295)
      (push-u64! (&mut out) -2)
      (push-u16! (&mut out) 74565)
      (let
        [bytes : (__tl_dyn-array u8)
          (byte_buf_core.byte-buf-builder-finish-array (& out))]
        (begin
          (test.assert-i64-eq (array-length bytes) 16 "encoded length")
          (test.assert-i64-eq
            (cast (array-ref bytes 0) : i64)
            220
            "u16 low byte first")
          (test.assert-i64-eq
            (cast (array-ref bytes 1) : i64)
            254
            "u16 high byte second")
          (test.assert-i64-eq (read-u16 (& bytes) 0) 65244 "u16 round trip")
          (test.assert-i64-eq
            (read-u32 (& bytes) 2)
            4294967295
            "u32 reads back zero-extended")
          (test.assert-i64-eq
            (read-u64 (& bytes) 6)
            -2
            "u64 keeps the sign bit")
          (test.assert-i64-eq
            (cast (array-ref bytes 13) : i64)
            255
            "u64 most significant byte last")
          (test.assert-i64-eq
            (read-u16 (& bytes) 14)
            9029
            "u16 keeps only the low 16 bits"))))))

(test
  byte-le-set-overwrites-in-place
  (let
    [bytes : (__tl_dyn-array u8) (__tl_make-array u8 16)]
    (begin
      (set-u64! (&mut bytes) 0 1311768467294899695)
      (test.assert-i64-eq
        (cast (array-ref bytes 0) : i64)
        239
        "u64 least significant byte first")
      (test.assert-i64-eq
        (read-u64 (& bytes) 0)
        1311768467294899695
        "u64 set round trip")
      (set-u32! (&mut bytes) 8 -1)
      (test.assert-i64-eq (read-u32 (& bytes) 8) 4294967295 "u32 set low bits")
      (test.assert-i64-eq (read-u16 (& bytes) 12) 0 "u32 set leaves neighbors")
      (set-u16! (&mut bytes) 12 513)
      (test.assert-i64-eq (read-u16 (& bytes) 12) 513 "u16 set round trip")
      (test.assert-i64-eq
        (read-u64 (& bytes) 8)
        2207613190143
        "u16 and u32 fields compose into one u64"))))