;; Runtime coverage for affine loop-versioning guards. The success case
;; exercises scaled and negative-offset induction. The trap cases cover a
;; scaled index that wraps negative and an offset index below zero: the
;; quotient guards must retain the checked slow path and its ordinary bounds
;; abort.
(import stdlib.array)
(import stdlib.io)
(import stdlib.string)

(define (scaled-sum [items : (Array i64)] [start : i64] [end : i64]) : i64
  (let
    [i : i64 start]
    [sum : i64 0]
    (begin
      (while (< i end)
        (begin
          (set! sum (+ sum (array-ref items (* i 3))))
          (set! i (+ i 1))))
      sum)))

(define (offset-sum [items : (Array i64)] [start : i64] [end : i64]) : i64
  (let
    [i : i64 start]
    [sum : i64 0]
    (begin
      (while (< i end)
        (begin
          (set! sum (+ sum (array-ref items (- i 2))))
          (set! i (+ i 1))))
      sum)))

(define (success) : i64
  (let
    [items : (Array i64) (array.make-array i64 10)]
    (begin
      (array-set! items 0 10)
      (array-set! items 1 20)
      (array-set! items 2 12)
      (array-set! items 3 20)
      (array-set! items 6 12)
      (if (and (= (scaled-sum items 0 3) 42) (= (offset-sum items 2 5) 42))
        42
        1))))

(define (overflow-trap) : i64
  (let
    [items : (Array i64) (array.make-array i64 8)]
    [start : i64 3074457345618258603]
    (scaled-sum items start (+ start 1))))

(define (underflow-trap) : i64
  (offset-sum (array.make-array i64 8) 0 1))

(define (main) : i64
  (match (string.>int (io.arg 1))
    [0 (success)]
    [1 (overflow-trap)]
    [_ (underflow-trap)]))