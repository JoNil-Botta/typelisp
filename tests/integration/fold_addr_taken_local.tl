;; Block-local fold keeps no copy or constant fact for an address-taken local
;; (#7973). A call or store through the exposed address redefines the local
;; without naming it, so a `set!` value, a copy of the local, or a copy into it
;; must not be forwarded past that write. Exits 42, or the number of the failed
;; check.
;; Writes 7 through `p` at the bottom of a short recursion, so the write sits in
;; a callee the block-local fold cannot see into.
(define (write-seven [p : (MutPtr i64)] [depth : i64]) : i32
  (if (> depth 0)
    (write-seven p (- depth 1))
    (begin
      (unsafe
        (ptr-write! p 7))
      (cast 1 : i32))))

;; The issue's reproducer: the final read sees the 7 written through `p`, not
;; the 5 of the preceding `set!`.
(define (set-after-addr [depth : i64]) : i64
  (let
    [value : i64 0]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of value))]
    (set! value 5)
    (write-seven p depth)
    value))

;; The loop variant: each iteration's `set!` is overwritten by the call.
(define (loop-set-after-addr [depth : i64]) : i64
  (let
    [value : i64 0]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of value))]
    [sum : i64 0]
    [i : i64 0]
    (while (< i 2)
      (set! value 1)
      (write-seven p depth)
      (set! sum (+ sum value))
      (set! i (+ i 1)))
    sum))

;; A copy taken before the write keeps the old value: `saved` must not be
;; replaced by `value` after the call.
(define (copy-before-write [depth : i64]) : i64
  (let
    [value : i64 0]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of value))]
    (set! value 3)
    (let
      [saved : i64 value]
      (write-seven p depth)
      (+ saved value))))

;; An expression of the local recomputed after the write sees the new value.
(define (expr-after-write [depth : i64]) : i64
  (let
    [value : i64 3]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of value))]
    [before : i64 (+ value 1)]
    (write-seven p depth)
    (+ before (+ value 1))))

(define (main) : i64
  (cond
    [(!= (set-after-addr 3) 7) 1]
    [(!= (loop-set-after-addr 2) 14) 2]
    [(!= (copy-before-write 1) 10) 3]
    [(!= (expr-after-write 0) 12) 4]
    [else 42]))