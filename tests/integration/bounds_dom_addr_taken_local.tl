;; bounds_dom keeps no copy, comparison or checked-pair fact for an
;; address-taken local (#8672). A store through the exposed address redefines
;; the local without naming it, so neither the local nor a copy of it may stand
;; for the local's value past that store.
;;
;; Run as `bounds_dom_addr_taken_local START TO MODE`. Mode 0 runs every check
;; and exits 42, or the number of the failed check. Modes 1 and 2 read `items`
;; at START, move the index to TO through its address and read again, exiting
;; with the sum of the two reads: an out-of-range TO must abort at the second
;; read.
(import stdlib.io)
(import stdlib.string)

;; The write sits in a callee, where bounds_dom cannot see it.
(define (write-through [p : (MutPtr i64)] [value : i64]) : unit
  (unsafe
    (ptr-write! p value)))

;; The issue's reproducer: `copy` holds the 1 read before the store, so the
;; `copy == 1` edge says nothing about `value` after it.
(define (copy-then-equal) : i64
  (let
    [value : i64 1]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of value))]
    [copy : i64 value]
    (write-through p 99)
    (if (= copy 1)
      (if (= value 99)
        42
        2)
      1)))

;; The local's own test before the store does not decide a test after it.
(define (equal-then-store) : i64
  (let
    [value : i64 1]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of value))]
    (if (= value 1)
      (begin
        (write-through p 99)
        (if (= value 99)
          42
          2))
      1)))

;; The store written in the function's own body rather than in a callee.
(define (copy-then-inline-store) : i64
  (let
    [value : i64 1]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of value))]
    [copy : i64 value]
    (unsafe
      (ptr-write! p 99))
    (if (= copy 1)
      (if (= value 99)
        42
        2)
      1)))

;; A passed bounds check of `index` says nothing once a store through its
;; address has moved it.
(define (check-then-move [start : i64] [to : i64]) : i64
  (let
    [items : (Array i64 4) (array 40 1 2 3)]
    [index : i64 start]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of index))]
    [first : i64 (array-ref items index)]
    (write-through p to)
    (+ first (array-ref items index))))

;; The same, with the first check made through a copy taken before the store.
(define (copy-check-then-move [start : i64] [to : i64]) : i64
  (let
    [items : (Array i64 4) (array 40 1 2 3)]
    [index : i64 start]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of index))]
    [copy : i64 index]
    [first : i64 (array-ref items copy)]
    (write-through p to)
    (+ first (array-ref items index))))

(define (main) : i64
  (let
    [start : i64 (string.>int (io.arg 1))]
    [to : i64 (string.>int (io.arg 2))]
    [mode : i64 (string.>int (io.arg 3))]
    (cond
      [(= mode 1) (check-then-move start to)]
      [(= mode 2) (copy-check-then-move start to)]
      [(!= (copy-then-equal) 42) 1]
      [(!= (equal-then-store) 42) 2]
      [(!= (copy-then-inline-store) 42) 3]
      [(!= (check-then-move start to) 42) 4]
      [(!= (copy-check-then-move start to) 42) 5]
      [else 42])))