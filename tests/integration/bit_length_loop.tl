;# BITLEN: counting significant bits with a shift loop becomes one `bsr` at
;# opt 2. Every shape below must agree, at every level, with a reference that
;# tests each bit position and so is never the idiom. Inputs come from argv so
;# nothing folds.
(import stdlib.io)
(import stdlib.string)

(define (reference-bits [n : i64]) : i64
  (if (<= n 0)
    0
    (let
      [k : i64 62]
      [found : i64 0]
      (begin
        (while (and (>= k 0) (= found 0))
          (begin
            (when (not (= (bit-and n (shl 1 k)) 0)) (set! found (+ k 1)))
            (set! k (- k 1))))
        found))))

;; The rotated `while` with its own `probe > 0` guard.
(define (while-bits [n : i64]) : i64
  (let
    [bits : i64 0]
    [probe : i64 n]
    (begin
      (while (> probe 0)
        (begin
          (set! probe (shr probe 1))
          (set! bits (+ bits 1))))
      bits)))

;; The loop behind an earlier `n <= 0` early return (the false edge proves it).
(define (guarded-bits [n : i64]) : i64
  (if (<= n 0)
    0
    (let
      [bits : i64 0]
      [probe : i64 n]
      (begin
        (while (> probe 0)
          (begin
            (set! probe (shr probe 1))
            (set! bits (+ bits 1))))
        bits))))

;; A counter that does not start at zero.
(define (offset-bits [n : i64]) : i64
  (let
    [bits : i64 100]
    [probe : i64 n]
    (begin
      (while (> probe 0)
        (begin
          (set! bits (+ bits 1))
          (set! probe (shr probe 1))))
      bits)))

;; Unsigned: a logical shift, and the top bit counts.
(define (unsigned-bits [n : u64]) : u64
  (let
    [bits : u64 (cast 0 : u64)]
    [probe : u64 n]
    (begin
      (while (> probe (cast 0 : u64))
        (begin
          (set! probe (shr probe 1))
          (set! bits (+ bits (cast 1 : u64)))))
      bits)))

(define (unsigned-reference [n : u64]) : i64
  (if (< (cast n : i64) 0)
    64
    (reference-bits (cast n : i64))))

(define (check [n : i64]) : bool
  (let
    [want : i64 (reference-bits n)]
    (and
      (= (while-bits n) want)
      (= (guarded-bits n) want)
      (= (offset-bits n) (+ want 100))
      (=
        (cast (unsigned-bits (cast n : u64)) : i64)
        (unsigned-reference (cast n : u64))))))

(define (main) : i64
  (let
    [count : i64 (io.arg-count)]
    [i : i64 1]
    [ok : bool true]
    (begin
      (while (< i count)
        (let
          [n : i64 (string.>int (io.arg i))]
          (begin
            (io.println "{}" (while-bits n))
            (unless (check n) (set! ok false))
            (set! i (+ i 1)))))
      (if ok
        42
        1))))