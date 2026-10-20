(import stdlib.io)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector i64) as vec)

(define (fresh [count : i64]) : vec.Vec
  (vec.Vec (__tl_make-array i64 count) count))

(define reads : vec.Vec
  (fresh 8))
(define writes : vec.Vec
  (fresh 8))
(define replaced : vec.Vec
  (fresh 8))

(define (read-at [index : i64]) : i64
  (array-ref (vec.slots (& reads)) index))

(define (written-at [index : i64]) : i64
  (array-ref (vec.slots (& writes)) index))

(define (set-read-at [index : i64] [value : i64]) : unit
  (set! (array-ref (vec.slots-mut (&mut reads)) index) value))

(define (write-at [index : i64] [value : i64]) : unit
  (set! (array-ref (vec.slots-mut (&mut writes)) index) value))

(define (replacement-at [index : i64]) : i64
  (array-ref (vec.slots (& replaced)) index))

(define (set-replacement-at [index : i64] [value : i64]) : unit
  (set! (array-ref (vec.slots-mut (&mut replaced)) index) value))

(define (disjoint [count : i64] [index : i64]) : i64
  (let
    ;; This access establishes the bound before even a zero-trip loop.
    [sum : i64 (read-at index)]
    [i : i64 0]
    (while (< i count)
      (write-at index i)
      (+= sum (read-at index))
      (+= i 1))
    sum))

(define (same-owner [count : i64] [index : i64]) : i64
  (let
    [sum : i64 (written-at index)]
    [i : i64 0]
    (while (< i count)
      (write-at index i)
      (+= sum (written-at index))
      (+= i 1))
    sum))

(define (conditional-read [count : i64] [index : i64]) : i64
  (let
    [sum : i64 0]
    [i : i64 0]
    (while (< i count)
      (write-at 0 i)
      (+= sum (read-at index))
      (+= i 1))
    sum))

(define (replace-owner [count : i64] [index : i64]) : i64
  (let
    [sum : i64 (replacement-at index)]
    [i : i64 0]
    (while (< i count)
      (set! replaced (fresh 8))
      (set-replacement-at index i)
      (+= sum (replacement-at index))
      (+= i 1))
    sum))

(define (main) : i64
  (let
    [limit : i64 (string.>int (io.arg 1))]
    [seed : i64 (string.>int (io.arg 2))]
    [index : i64 (string.>int (io.arg 3))]
    [count : i64 0]
    [ok? : bool
      (and
        (= (conditional-read 0 -1) 0)
        (= (conditional-read 0 1099511627776) 0))]
    (while (and ok? (<= count limit))
      (set-read-at index seed)
      (write-at index seed)
      (set! ok? (= (disjoint count index) (* seed (+ count 1))))
      (write-at index seed)
      (set!
        ok?
        (and
          ok?
          (= (same-owner count index) (+ seed (/ (* count (- count 1)) 2)))))
      (set-replacement-at index seed)
      (set!
        ok?
        (and
          ok?
          (= (replace-owner count index) (+ seed (/ (* count (- count 1)) 2)))))
      (+= count 1))
    (if ok?
      42
      1)))