;; The source increment precedes the shift; the replacement's bit-length
;; definition must precede its dependent add, for both signednesses and seeds.
(import stdlib.io)
(import stdlib.string)

(define (signed-bits [value : i64] [seed : i64]) : i64
  (let
    [probe : i64 value]
    [bits : i64 seed]
    (begin
      (while (> probe 0)
        (begin
          (set! bits (+ bits 1))
          (set! probe (shr probe 1))))
      bits)))

(define (unsigned-bits [value : u64] [seed : u64]) : u64
  (let
    [probe : u64 value]
    [bits : u64 seed]
    (begin
      (while (> probe 0)
        (begin
          (set! bits (+ bits 1))
          (set! probe (shr probe 1))))
      bits)))

(define (main) : i64
  (let
    [seed : i64 (string.>int (io.arg 1))]
    [value : i64 (string.>int (io.arg 2))]
    (begin
      (io.println "{}" (signed-bits value seed))
      (io.println "{}" (unsigned-bits (cast value : u64) (cast seed : u64)))
      0)))