(import stdlib.io)
(import stdlib.vector)
(import (vector.vector i64) as i64vec)

;; FORCING TEST for region-scoped scalar global-cell reads inside loops that
;; write the cell (MF-5 (i), #7926).
;;
;; An append cursor is read once per element store and advanced once per
;; record: `buf[n] = a; buf[n + 1] = b; buf[n + 2] = c; n += 3`. Every read of
;; `n` is a hidden rip-relative load, the loop itself stores `n`, so no loop
;; pass can hoist or collapse the reads; the load-CSE has to share one value per
;; write-free region, across the element stores between the reads.
;;
;; The four shapes below are WRONG-ANSWER guards for the places where sharing
;; would be unsound or is deliberately left alone:
;;
;;   append-records   shared     -- element stores between the reads; the cell is
;;                                  stored once per iteration.
;;   bumped-records   not shared -- a call that stores the cell sits between two
;;                                  reads, so the second read must observe it.
;;   nested-total     mixed      -- only the OUTER loop stores the cell; the
;;                                  inner loop reads it twice per iteration and
;;                                  must see the value of the current outer
;;                                  iteration.
;;   restored-cursor  not shared -- the cell is stored between the two reads in
;;                                  the same block.
;;
;; Every result is compared with a twin that keeps the cursor in a local.
(define records : i64vec.Vec
  (i64vec.Vec (__tl_make-array i64 4096) 4096))
(define cursor : i64
  0)
(define total : i64
  0)

(define (record-set! [index : i64] [value : i64]) : unit
  (set! (array-ref (i64vec.slots-mut (&mut records)) index) value))

(define (record-ref [index : i64]) : i64
  (array-ref (i64vec.slots (& records)) index))

(define (append-records [n : i64]) : i64
  (let
    [i : i64 0]
    (begin
      (set! cursor 0)
      (while (< i n)
        (begin
          (record-set! cursor i)
          (record-set! (+ cursor 1) (* i 3))
          (record-set! (+ cursor 2) (+ cursor i))
          (set! cursor (+ cursor 3))
          (set! i (+ i 1))))
      cursor)))

(define (append-twin [n : i64]) : i64
  (let
    [i : i64 0]
    [local : i64 0]
    [sum : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! sum (+ sum (+ i (+ (* i 3) (+ local i)))))
          (set! local (+ local 3))
          (set! i (+ i 1))))
      sum)))

(define (records-sum [count : i64]) : i64
  (let
    [i : i64 0]
    [sum : i64 0]
    (begin
      (while (< i count)
        (begin
          (set! sum (+ sum (record-ref i)))
          (set! i (+ i 1))))
      sum)))

;; Recursive so it stays a call: it stores the cell `depth` times.
(define (bump-cursor [depth : i64]) : unit
  (if (> depth 0)
    (begin
      (set! cursor (+ cursor 1))
      (bump-cursor (- depth 1)))
    unit))

(define (bumped-records [n : i64] [depth : i64]) : i64
  (let
    [i : i64 0]
    [sum : i64 0]
    (begin
      (set! cursor 0)
      (while (< i n)
        (begin
          (record-set! cursor i)
          (bump-cursor depth)
          (record-set! cursor (+ i 1))
          (set! sum (+ sum cursor))
          (set! cursor (+ cursor 1))
          (set! i (+ i 1))))
      sum)))

(define (bumped-twin [n : i64] [depth : i64]) : i64
  (let
    [i : i64 0]
    [sum : i64 0]
    [local : i64 0]
    (begin
      (while (< i n)
        (begin
          (set! local (+ local depth))
          (set! sum (+ sum local))
          (set! local (+ local 1))
          (set! i (+ i 1))))
      sum)))

(define (nested-total [rows : i64] [cols : i64]) : i64
  (let
    [r : i64 0]
    [sum : i64 0]
    (begin
      (set! total 1)
      (while (< r rows)
        (let
          [c : i64 0]
          (begin
            (while (< c cols)
              (begin
                (set! sum (+ sum (+ total (* total c))))
                (set! c (+ c 1))))
            (set! total (+ total (+ total r)))
            (set! r (+ r 1)))))
      sum)))

(define (nested-twin [rows : i64] [cols : i64]) : i64
  (let
    [r : i64 0]
    [sum : i64 0]
    [local : i64 1]
    (begin
      (while (< r rows)
        (let
          [c : i64 0]
          (begin
            (while (< c cols)
              (begin
                (set! sum (+ sum (+ local (* local c))))
                (set! c (+ c 1))))
            (set! local (+ local (+ local r)))
            (set! r (+ r 1)))))
      sum)))

(define (restored-cursor [n : i64]) : i64
  (let
    [i : i64 0]
    [sum : i64 0]
    (begin
      (set! cursor 5)
      (while (< i n)
        (let
          [before : i64 (+ cursor i)]
          (begin
            (set! cursor (+ cursor 2))
            (set! sum (+ sum (+ before (* cursor 7))))
            (set! i (+ i 1)))))
      sum)))

(define (restored-twin [n : i64]) : i64
  (let
    [i : i64 0]
    [sum : i64 0]
    [local : i64 5]
    (begin
      (while (< i n)
        (let
          [before : i64 (+ local i)]
          (begin
            (set! local (+ local 2))
            (set! sum (+ sum (+ before (* local 7))))
            (set! i (+ i 1)))))
      sum)))

(define (main) : i64
  (let
    [n : i64 (+ (io.arg-count) 40)]
    [depth : i64 (+ (io.arg-count) 2)]
    [appended : i64 (append-records n)]
    [append-sum : i64 (records-sum appended)]
    [append-want : i64 (append-twin n)]
    [bumped : i64 (bumped-records n depth)]
    [bumped-want : i64 (bumped-twin n depth)]
    [nested : i64 (nested-total (+ (io.arg-count) 6) (+ (io.arg-count) 4))]
    [nested-want : i64 (nested-twin (+ (io.arg-count) 6) (+ (io.arg-count) 4))]
    [restored : i64 (restored-cursor n)]
    [restored-want : i64 (restored-twin n)]
    (if (and
      (= appended (* n 3))
      (= append-sum append-want)
      (= bumped bumped-want)
      (= nested nested-want)
      (= restored restored-want))
      42
      1)))