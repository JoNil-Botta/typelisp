;# Incremental Adler-32 checksums (RFC 1950 section 8.2).
;#
;# A checksum is the 32-bit value `b * 65536 + a`; start from `initial` and
;# fold borrowed chunks with `update`. Any chunking of the same bytes gives
;# the same value. It detects accidental corruption and authenticates nothing.
;#
;# Usage: `(import stdlib.compress.adler32)`, then
;# `(adler32.update (adler32.initial) bytes)` or `(adler32.checksum bytes)`.
(import stdlib.byte_buf)

;: The checksum of empty input.
(define (initial) : i64
  1)

;: Fold `input` into a running checksum. Only the low 16 bits of each half are
;: read, so every argument is safe. Sums are reduced at least every 5552 bytes
;: (zlib's 32-bit bound), far below signed 64-bit overflow.
(define (update [checksum : i64] [input : (& input bytes)]) : i64
  (let
    [a : i64 (% (bit-and checksum 65535) 65521)]
    [b : i64 (% (bit-and (shr checksum 16) 65535) 65521)]
    [length : i64 (byte_buf.bytes-length input)]
    [index : i64 0]
    (while (< index length)
      (let
        [end : i64
          (if (< (- length index) 5552)
            length
            (+ index 5552))]
        (while (< index end)
          (set! a (+ a (cast (byte_buf.bytes-ref input index) : i64)))
          (set! b (+ b a))
          (set! index (+ index 1)))
        (set! a (% a 65521))
        (set! b (% b 65521))))
    (bit-or (shl b 16) a)))

;: The checksum of one complete byte sequence.
(define (checksum [input : (& input bytes)]) : i64
  (update (initial) input))