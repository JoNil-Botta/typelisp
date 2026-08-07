;# benchmarks/opt_crc32/bench.tl - table-driven CRC-32 workload.
;#
;# Equivalent to benchmarks/opt_crc32/baseline.c. Builds the standard reflected
;# CRC-32 (polynomial 0xEDB88320) lookup table once, then checksums a byte
;# buffer many rounds, perturbing one buffer byte per round so the work cannot be
;# constant-folded, and folds each round's CRC into a wrapping accumulator.
;# Exercises bitwise ops (xor / shift / and), 256-entry table lookups, and
;# direct access to a `Vec`'s inferred backing storage. The buffer length and
;# round count are runtime
;# arguments; the accumulator stays in [0, 2^32) so its printed decimal matches
;# the C baseline.
(import stdlib.array)
(import stdlib.io)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector i64) as i64vec)
(import (vector.vector u8) as u8vec)

(define crc-low-mask : i64
  4294967295)
(define crc-byte-mask : i64
  255)
(define crc-poly : i64
  3988292384)

(define (crc-table-entry [n : i64]) : i64
  (let
    [crc : i64 n]
    [bit : i64 0]
    (begin
      (while (< bit 8)
        (begin
          (if (= (bit-and crc 1) 1)
            (set! crc (bit-xor (shr crc 1) crc-poly))
            (set! crc (shr crc 1)))
          (set! bit (+ bit 1))))
      crc)))

(define (crc-build-table) : i64vec.Vec
  (let
    [table : i64vec.Vec (i64vec.Vec (array.make-array i64 256) 256)]
    [slots (i64vec.slots-mut (&mut table))]
    [n : i64 0]
    (begin
      (while (< n 256)
        (begin
          (array-set! slots n (crc-table-entry n))
          (set! n (+ n 1))))
      table)))

(define (crc-update
  [table : (& table i64vec.Vec)]
  [buf : (&mut buf u8vec.Vec)]
  [len : i64]) : i64
  (let
    [table-slots (i64vec.slots table)]
    [buf-slots (u8vec.slots-mut buf)]
    [crc : i64 crc-low-mask]
    [i : i64 0]
    (begin
      (while (< i len)
        (begin
          (let
            [byte : i64 (cast (array-ref buf-slots i) : i64)]
            [index : i64 (bit-and (bit-xor crc byte) crc-byte-mask)]
            (set! crc (bit-xor (shr crc 8) (array-ref table-slots index))))
          (set! i (+ i 1))))
      (bit-xor crc crc-low-mask))))

(define (crc-fill [buf : (&mut buf u8vec.Vec)] [len : i64]) : unit
  (let
    [slots (u8vec.slots-mut buf)]
    [i : i64 0]
    (begin
      (while (< i len)
        (begin
          (array-set! slots i (cast (bit-and (+ (* i 167) 13) 255) : u8))
          (set! i (+ i 1))))
      unit)))

(define (crc-bench [len : i64] [rounds : i64]) : i64
  (let
    [table : i64vec.Vec (crc-build-table)]
    [buf : u8vec.Vec (u8vec.Vec (array.make-array u8 len) len)]
    [round : i64 0]
    [acc : i64 0]
    (begin
      (crc-fill (&mut buf) len)
      (while (< round rounds)
        (begin
          (u8vec.set
            (&mut buf)
            (% round len)
            (cast (bit-and (+ round 1) 255) : u8))
          (set!
            acc
            (bit-and (+ acc (crc-update (& table) (&mut buf) len)) crc-low-mask))
          (set! round (+ round 1))))
      acc)))

(define (main) : i64
  (let
    [len : i64 (string.>int (io.arg 1))]
    [rounds : i64 (string.>int (io.arg 2))]
    (begin
      (io.print (crc-bench len rounds))
      0)))