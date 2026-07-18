;# Checked-reference load-GVN benchmark (#5201).
;#
;# `borrowed-disjoint-store-loop` repeatedly reads through an immutable checked
;# reference while writing through a distinct exclusive mutable reference.
;# Root-aware LICM can move the invariant read out of the loop.
(import stdlib.io)

(defstruct BorrowedPair
  (x i64)
  (y i64))

(define borrowed-disjoint-store-base-iterations : i64
  100000000)

(define (borrowed-disjoint-store-loop
  [read : (& read BorrowedPair)]
  [write : (&mut write BorrowedPair)]
  [iterations : i64]) : i64
  (let
    [acc : i64 0]
    [i : i64 0]
    (begin
      (while (< i iterations)
        (begin
          (set! (struct-get write y) i)
          (set! (struct-get write x) (+ (struct-get read x) i))
          (set! acc (+ acc (struct-get read x)))
          (set! i (+ i 1))))
      acc)))

(define (main) : i64
  (let
    [left : BorrowedPair (BorrowedPair 17 0)]
    [right : BorrowedPair (BorrowedPair 23 0)]
    [iterations : i64
      (+ borrowed-disjoint-store-base-iterations (io.arg-count))]
    [first-iterations : i64 (/ iterations 2)]
    [second-iterations : i64 (- iterations first-iterations)]
    [first : i64
      (borrowed-disjoint-store-loop (& left) (&mut right) first-iterations)]
    [second : i64
      (borrowed-disjoint-store-loop (& left) (&mut right) second-iterations)]
    (begin
      (bit-and (+ first second) 255))))