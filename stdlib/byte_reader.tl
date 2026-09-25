;# Bounded cursor over little-endian binary input.
;#
;# A `ByteReader` walks `bytes[offset, end)` for decoders of untrusted binary
;# formats. Every read is bounds-checked, and the first failure is sticky: the
;# reader records its code, byte offset, and message, later reads return `0`
;# without touching the cursor, and later failures are ignored, so a decoder can
;# run a whole record and inspect `ok?` once. A work limit bounds the total
;# number of bytes a decode may consume, which caps the cost of hostile input
;# that repeats expensive reads.
;#
;# The reader's own failures use the negative codes `error-truncated` and
;# `error-work-limit`; `fail!` records any caller-defined code (for example a
;# schema or validation error) under the same first-failure rule. Integers use
;# the byte order of `stdlib.byte_le`.
;#
;# `new` shares the caller's `__tl_dyn-array u8` storage instead of copying it
;# and the reader never allocates; failure messages are static strings unless a
;# caller passes its own to `fail!`.
;#
;# Usage: `(import stdlib.byte_reader)`
;#
;# ```typelisp
;# (import stdlib.byte_reader)
;# (define (main) : i64
;#   (let
;#     [bytes : (__tl_dyn-array u8) (__tl_make-array u8 4)]
;#     [reader : byte_reader.ByteReader
;#       (byte_reader.new bytes byte_reader.unlimited-work)]
;#     [value : i64 (byte_reader.read-u32! (&mut reader))]
;#     (if (byte_reader.at-end? (& reader))
;#       value
;#       -1)))
;# ```
(import stdlib.byte_le)
(cfg test (import stdlib.test))

;: Error code recorded when a read or `consume!` runs past `end`.
(define error-truncated : i64
  -1)

;: Error code recorded when a `consume!` would exceed the work limit.
(define error-work-limit : i64
  -2)

;: Error code for a caller's own validation failure when the caller keeps no
;: error codes of its own.
(define error-invalid : i64
  -3)

;: A work limit that no input can reach.
(define unlimited-work : i64
  9223372036854775807)

;: Cursor over `bytes[offset, end)` with a sticky first failure. `ok?` stays
;: true until a failure; `error-code`, `error-offset` and `error-message`
;: describe that first failure. `work` counts the bytes consumed so far
;: against `max-work`.
(defstruct ByteReader
  (bytes (__tl_dyn-array u8))
  (offset i64)
  (end i64)
  (ok? bool)
  (error-code i64)
  (error-offset i64)
  (error-message String)
  (work i64)
  (max-work i64))

;: A reader over all of `bytes` that may consume at most `max-work` bytes.
;: The reader shares `bytes` with the caller; it does not copy them.
(define (new [bytes : (__tl_dyn-array u8)] [max-work : i64]) : ByteReader
  (let
    [end : i64 (array-length bytes)]
    (ByteReader bytes 0 end true 0 0 "" 0 max-work)))

;: Record a failure at `offset` unless one is already recorded, so the
;: earliest cause is the one reported.
(define (fail!
  [reader : (&mut reader ByteReader)]
  [code : i64]
  [offset : i64]
  [message : String]) : unit
  (if reader.ok?
    (begin
      (set! reader.ok? false)
      (set! reader.error-code code)
      (set! reader.error-offset offset)
      (set! reader.error-message message))
    unit))

;: True when `[start, start + count)` lies inside a sequence of `length` bytes.
(define (range-present? [length : i64] [start : i64] [count : i64]) : bool
  (and (>= start 0) (>= count 0) (<= start length) (<= count (- length start))))

;: True while the reader has not failed and at least `count` bytes remain.
(define (available? [reader : (& reader ByteReader)] [count : i64]) : bool
  (and reader.ok? (range-present? reader.end reader.offset count)))

;: True when the reader has not failed and consumed its input exactly.
(define (at-end? [reader : (& reader ByteReader)]) : bool
  (and reader.ok? (= reader.offset reader.end)))

;: Check that the next `count` bytes are present and charge them to the work
;: limit, without moving the cursor. Returns false, recording
;: `error-truncated` or `error-work-limit` at the cursor, when either check
;: fails, and false without recording anything after an earlier failure.
(define (consume! [reader : (&mut reader ByteReader)] [count : i64]) : bool
  (cond
    [(not reader.ok?) false]
    [(not (range-present? reader.end reader.offset count))
      (begin
        (fail!
          reader
          error-truncated
          reader.offset
          "byte reader: input is truncated")
        false)]
    [(> count (- reader.max-work reader.work))
      (begin
        (fail!
          reader
          error-work-limit
          reader.offset
          "byte reader: work limit exceeded")
        false)]
    [else
      (begin
        (set! reader.work (+ reader.work count))
        true)]))

;: Move the cursor past `count` bytes that a successful `consume!` covered.
(define (skip! [reader : (&mut reader ByteReader)] [count : i64]) : unit
  (set! reader.offset (+ reader.offset count)))

;: Consume and return the next byte, or `0` after a failure.
(define (read-u8! [reader : (&mut reader ByteReader)]) : i64
  (if (consume! reader 1)
    (let
      [offset : i64 reader.offset]
      (begin
        (skip! reader 1)
        (cast (array-ref reader.bytes offset) : i64)))
    0))

;: Consume and return the next zero-extended 16-bit value, or `0` after a
;: failure.
(define (read-u16! [reader : (&mut reader ByteReader)]) : i64
  (if (consume! reader 2)
    (let
      [offset : i64 reader.offset]
      (begin
        (skip! reader 2)
        (byte_le.read-u16 (& reader.bytes) offset)))
    0))

;: Consume and return the next zero-extended 32-bit value, or `0` after a
;: failure.
(define (read-u32! [reader : (&mut reader ByteReader)]) : i64
  (if (consume! reader 4)
    (let
      [offset : i64 reader.offset]
      (begin
        (skip! reader 4)
        (byte_le.read-u32 (& reader.bytes) offset)))
    0))

;: Consume and return the next 64-bit pattern as an `i64`, or `0` after a
;: failure.
(define (read-u64! [reader : (&mut reader ByteReader)]) : i64
  (if (consume! reader 8)
    (let
      [offset : i64 reader.offset]
      (begin
        (skip! reader 8)
        (byte_le.read-u64 (& reader.bytes) offset)))
    0))

(cfg
  test
  (define (byte-reader-test-bytes) : (__tl_dyn-array u8)
    (let
      [bytes : (__tl_dyn-array u8) (__tl_make-array u8 15)]
      [index : i64 0]
      (begin
        (while (< index 15)
          (begin
            (set! (array-ref bytes index) (cast (+ index 1) : u8))
            (set! index (+ index 1))))
        bytes))))

(test
  byte-reader-reads-in-order
  (let
    [reader : ByteReader (new (byte-reader-test-bytes) unlimited-work)]
    (begin
      (test.assert-i64-eq (read-u8! (&mut reader)) 1 "u8")
      (test.assert-i64-eq (read-u16! (&mut reader)) 770 "u16")
      (test.assert-i64-eq (read-u32! (&mut reader)) 117835012 "u32")
      (test.assert-i64-eq (read-u64! (&mut reader)) 1084818905618843912 "u64")
      (test.assert-true (at-end? (& reader)) "consumed exactly")
      (test.assert-i64-eq reader.work 15 "work counts consumed bytes"))))

(test
  byte-reader-truncation-is-sticky
  (let
    [reader : ByteReader (new (byte-reader-test-bytes) unlimited-work)]
    (begin
      (test.assert-i64-eq (read-u64! (&mut reader)) 578437695752307201 "u64")
      (test.assert-true (available? (& reader) 7) "seven bytes remain")
      (test.assert-false (available? (& reader) 8) "eight do not")
      (test.assert-i64-eq (read-u64! (&mut reader)) 0 "truncated read")
      (test.assert-false reader.ok? "failed")
      (test.assert-i64-eq reader.error-code error-truncated "truncated code")
      (test.assert-i64-eq reader.error-offset 8 "failure offset")
      (test.assert-i64-eq reader.offset 8 "cursor stays put")
      (test.assert-i64-eq (read-u8! (&mut reader)) 0 "reads stay failed")
      (fail! (&mut reader) 7 0 "later failure")
      (test.assert-i64-eq
        reader.error-code
        error-truncated
        "first failure kept")
      (test.assert-false (available? (& reader) 0) "nothing after failure")
      (test.assert-false (at-end? (& reader)) "not a clean end"))))

(test
  byte-reader-work-limit
  (let
    [reader : ByteReader (new (byte-reader-test-bytes) 6)]
    (begin
      (test.assert-true (consume! (&mut reader) 4) "within the limit")
      (test.assert-i64-eq reader.offset 0 "consume does not move")
      (test.assert-false (consume! (&mut reader) 3) "over the limit")
      (test.assert-i64-eq reader.error-code error-work-limit "work code")
      (test.assert-i64-eq reader.work 4 "failed consume is not charged"))))

(test
  byte-reader-caller-failure
  (let
    [reader : ByteReader (new (__tl_make-array u8 0) unlimited-work)]
    (begin
      (test.assert-true (at-end? (& reader)) "empty input is at its end")
      (test.assert-false (consume! (&mut reader) -1) "negative count")
      (test.assert-i64-eq
        reader.error-code
        error-truncated
        "negative is truncated")
      (let
        [fresh : ByteReader (new (byte-reader-test-bytes) unlimited-work)]
        (begin
          (fail! (&mut fresh) 12 3 "schema")
          (test.assert-i64-eq fresh.error-code 12 "caller code")
          (test.assert-i64-eq fresh.error-offset 3 "caller offset")
          (test.assert-owned-string-eq fresh.error-message "schema" "message"))))))