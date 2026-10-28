;; Refs #8913: a read of an address-taken local is a load of its storage. Code
;; motion may not move it below a store through the local's address, a call
;; handed that address, or a direct def of the local. Most cases read the
;; local, or copy it, before such a write and use the value in only one arm of
;; a branch, the shape successor sinking moves into that arm; the last forms an
;; address from the local, the shape gep splitting re-forms at each use. Each
;; case returns 44 and recurses on an impossible guard, so it is not inlined
;; into `main` and keeps its own shape. Exits 42, or the number of the failed
;; check.
(import stdlib.io)

(defstruct P
  (x i64)
  (y i64))

;; Returns its argument through a recursion, so a branch on the result stays a
;; branch.
(define (opaque [x : i64]) : i64
  (if (> x 1000000)
    (opaque (- x 1))
    x))

;; Writes 3 through `p` at the bottom of a short recursion, so the store sits in
;; a callee.
(define (write-three [p : (MutPtr i64)] [depth : i64]) : unit
  (if (> depth 0)
    (write-three p (- depth 1))
    (unsafe
      (ptr-write! p 3))))

;; A plain copy, used in the `then` arm.
(define (copy-then [n : i64]) : i64
  (if (> n 1000000)
    (copy-then (- n 1))
    (let
      [x : i64 (+ 40 n)]
      [px : (MutPtr i64)
        (unsafe
          (ptr-addr-of x))]
      [a : i64 x]
      (unsafe
        (ptr-write! px 3))
      (if (> (opaque n) 0)
        (+ a x)
        0))))

;; A field of a struct copy, used in the `else` arm.
(define (struct-copy-else [n : i64]) : i64
  (if (> n 1000000)
    (struct-copy-else (- n 1))
    (let
      [x : i64 (+ 40 n)]
      [px : (MutPtr i64)
        (unsafe
          (ptr-addr-of x))]
      [a : P (P x 0)]
      [b : P a]
      (unsafe
        (ptr-write! px 3))
      (if (< (opaque n) 1)
        0
        (+ b.x x)))))

;; An expression of the local, used in the `else` arm.
(define (expr-else [n : i64]) : i64
  (if (> n 1000000)
    (expr-else (- n 1))
    (let
      [x : i64 (+ 40 n)]
      [px : (MutPtr i64)
        (unsafe
          (ptr-addr-of x))]
      [a : i64 (* x 1)]
      (unsafe
        (ptr-write! px 3))
      (if (< (opaque n) 1)
        0
        (+ a x)))))

;; Each arm reads its own expression of the local.
(define (both-arms [n : i64]) : i64
  (if (> n 1000000)
    (both-arms (- n 1))
    (let
      [x : i64 (+ 40 n)]
      [px : (MutPtr i64)
        (unsafe
          (ptr-addr-of x))]
      [a : i64 (+ x 0)]
      [c : i64 (- x 1)]
      (unsafe
        (ptr-write! px 3))
      (if (> (opaque n) 0)
        (+ a x)
        (+ (+ c x) 1)))))

;; The store is the only instruction between the read and the branch.
(define (store-only [n : i64]) : i64
  (if (> n 1000000)
    (store-only (- n 1))
    (let
      [x : i64 (+ 40 n)]
      [px : (MutPtr i64)
        (unsafe
          (ptr-addr-of x))]
      [a : i64 (+ x 0)]
      (unsafe
        (ptr-write! px 3))
      (if (> n 0)
        (+ a x)
        0))))

;; The store sits in a callee handed the address.
(define (callee-store [n : i64]) : i64
  (if (> n 1000000)
    (callee-store (- n 1))
    (let
      [x : i64 (+ 40 n)]
      [px : (MutPtr i64)
        (unsafe
          (ptr-addr-of x))]
      [a : i64 (+ x 0)]
      (write-three px n)
      (if (> (opaque n) 0)
        (+ a x)
        0))))

;; Each iteration reads the local, then stores through its address: the reads
;; are 41, 1 and 2 against the stores 1, 2 and 3, so the sum is 38.
(define (loop-carried [n : i64]) : i64
  (if (> n 1000000)
    (loop-carried (- n 1))
    (let
      [x : i64 (+ 40 n)]
      [px : (MutPtr i64)
        (unsafe
          (ptr-addr-of x))]
      [sum : i64 0]
      [i : i64 0]
      (while (< i 3)
        (let
          [a : i64 (+ x 0)]
          (unsafe
            (ptr-write! px (+ i 1)))
          (if (> n 0)
            (set! sum (+ sum (- a x)))
            unit))
        (set! i (+ i 1)))
      (+ sum 6))))

;; A direct `set!` of the local, read back through its address.
(define (set-then-read [n : i64]) : i64
  (if (> n 1000000)
    (set-then-read (- n 1))
    (let
      [x : i64 (+ 40 n)]
      [px : (MutPtr i64)
        (unsafe
          (ptr-addr-of x))]
      [a : i64 (+ x 0)]
      (set! x 3)
      (if (> (opaque n) 0)
        (+
          a
          (unsafe
            (ptr-read px)))
        0))))

;; A read through the address, then a direct `set!` of the local.
(define (read-then-set [n : i64]) : i64
  (if (> n 1000000)
    (read-then-set (- n 1))
    (let
      [x : i64 (+ 40 n)]
      [px : (MutPtr i64)
        (unsafe
          (ptr-addr-of x))]
      [a : i64
        (unsafe
          (ptr-read px))]
      (set! x 3)
      (if (> n 0)
        (+ a x)
        0))))

;; An element address formed from the local serves a load before the store
;; through the local's address and a store after it. Both use the element
;; chosen by the index read before that store: 4 read, then 40 written.
(define (split-address [n : i64]) : i64
  (if (> n 1000000)
    (split-address (- n 1))
    (let
      [items : (Array u8 4)
        (array (cast 0 : u8) (cast 4 : u8) (cast 0 : u8) (cast 0 : u8))]
      [i : i64 n]
      [pi : (MutPtr i64)
        (unsafe
          (ptr-addr-of i))]
      [p : (MutPtr u8)
        (unsafe
          (ptr-offset (ptr-cast (ptr-addr-of items) : (MutPtr u8)) i))]
      [a : u8
        (unsafe
          (ptr-read p))]
      (unsafe
        (ptr-write! pi 3))
      (unsafe
        (ptr-write! p (cast 40 : u8)))
      (+ (cast a : i64) (cast (array-ref items 1) : i64)))))

(define (main) : i64
  (let
    [n : i64 (io.arg-count)]
    (cond
      [(!= (copy-then n) 44) 1]
      [(!= (struct-copy-else n) 44) 2]
      [(!= (expr-else n) 44) 3]
      [(!= (both-arms n) 44) 4]
      [(!= (store-only n) 44) 5]
      [(!= (callee-store n) 44) 6]
      [(!= (loop-carried n) 44) 7]
      [(!= (set-then-read n) 44) 8]
      [(!= (read-then-set n) 44) 9]
      [(!= (split-address n) 44) 10]
      [else 42])))