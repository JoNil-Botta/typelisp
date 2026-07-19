;# Checked-reference load-GVN benchmark (#5201).
;#
;# `borrowed-disjoint-store-loop` repeatedly reads through an immutable checked
;# reference while a non-inlined direct helper writes through a distinct
;# exclusive mutable reference. Root-aware direct-call summaries keep the
;# invariant load available across the call.
(import stdlib.io)

(defstruct BorrowedPair
  (x i64)
  (y i64))

(define borrowed-disjoint-store-base-iterations : i64
  100000000)

(define (borrowed-disjoint-store-touch
  [write : (&mut write BorrowedPair)]
  [value : i64]) : unit
  ;; The pre-optimization body exceeds the inliner budget; the helper's own
  ;; scalar optimizer removes the identity chain before code generation.
  (let
    [a : i64 (+ value 0)]
    [b : i64 (+ a 0)]
    [c : i64 (+ b 0)]
    [d : i64 (+ c 0)]
    [e : i64 (+ d 0)]
    [f : i64 (+ e 0)]
    [g : i64 (+ f 0)]
    [h : i64 (+ g 0)]
    [i : i64 (+ h 0)]
    [j : i64 (+ i 0)]
    (set! (struct-get write y) j)))

(define (borrowed-disjoint-store-loop
  [read : (& read BorrowedPair)]
  [write : (&mut write BorrowedPair)]
  [iterations : i64]) : i64
  (let
    [acc : i64 0]
    [i : i64 0]
    (begin
      (while (< i iterations)
        (let
          [current : i64 (struct-get read x)]
          (begin
            (borrowed-disjoint-store-touch write i)
            (set! (struct-get write y) (struct-get read x))
            (set! (struct-get write x) (+ current i))
            (set! acc (+ acc (struct-get read x)))
            (set! i (+ i 1)))))
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
    (bit-and (+ first second) 255)))