;# Checked-reference load-GVN benchmark (#5201).
;#
;# `borrowed-step` reads through an immutable checked reference, writes through
;# a distinct exclusive mutable reference, then reads the immutable referent
;# again. Root-aware store filtering can reuse the first load.
(import stdlib.io)

(defstruct BorrowedPair
  (x i64)
  (y i64))

(define borrowed-disjoint-store-base-iterations : i64
  100000000)

(define (borrowed-disjoint-store-step
  [read : (& read BorrowedPair)]
  [write : (&mut write BorrowedPair)]
  [value : i64]) : unit
  (let
    [before : i64 (struct-get read x)]
    (begin
      (set! (struct-get write y) value)
      (set! (struct-get write x) (+ before (struct-get read x))))))

(define (main) : i64
  (let
    [left : BorrowedPair (BorrowedPair 17 0)]
    [right : BorrowedPair (BorrowedPair 23 0)]
    [iterations : i64
      (+ borrowed-disjoint-store-base-iterations (io.arg-count))]
    [acc : i64 0]
    [i : i64 0]
    (begin
      (while (< i iterations)
        (begin
          (borrowed-disjoint-store-step (& left) (&mut right) i)
          (set! acc (+ acc (struct-get right x)))
          (set! i (+ i 1))))
      (bit-and (+ acc (struct-get right y)) 255))))