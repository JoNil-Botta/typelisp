;; Specialization substitutes a template's type and value parameters through
;; every form that binds a name or carries a type, in one walk (#7534). Each
;; binder here shadows a comptime parameter, so a missed scope shows up as a
;; wrong sum.
(import stdlib.vector)
(import (vector.vector i64) as i64v)

(defenum Shape
  (Dot)
  (Line i64))

(define (let-forms [comptime T : type] [comptime n : i64]) : i64
  (let
    [a : T (cast n : T)]
    [n : i64 (+ (cast a : i64) 1)]
    [b : T (cast n : T)]
    (+ (cast b : i64) n)))

(define (lambda-forms [comptime T : type] [comptime n : i64]) : i64
  (let
    [add : (-> T T)
      (lambda ([x : T]) : T
        (+ x (cast n : T)))]
    [twice : (-> i64 i64)
      (lambda ([n : i64]) : i64
        (* n 2))]
    (+ (cast (add (cast 1 : T)) : i64) (twice 10))))

(define (match-forms [comptime n : i64]) : i64
  (let
    [line : Shape (Line 7)]
    [dot : Shape (Dot)]
    (+
      (match line
        [(Dot) 0]
        [(Line n) n])
      (match dot
        [(Dot) n]
        [(Line _) 0]))))

(define (foreach-forms [comptime T : type] [comptime n : i64]) : i64
  (let
    [out : (Array i64 8) (make-array i64 8)]
    [grid : (Array i64 8) (make-array i64 8)]
    (foreach
      ([i : T (cast 0 : T) (cast n : T)])
      (set! (array-ref out i) (+ i n)))
    (foreach ([n : i64 0 2]) (set! (array-ref out (+ n 6)) n))
    (foreach
      ([y : i64 0 2] [n : i64 0 4])
      (set! (array-ref grid (+ (* y 4) n)) n))
    (+
      (spmd-reduce sum ([i : i64 0 8]) 0 (array-ref out i))
      (spmd-reduce sum ([n : i64 0 8]) 0 (array-ref grid n)))))

(define (lane-forms [comptime n : i64]) : i64
  (let
    [out : (Array i64 4) (make-array i64 4)]
    (foreach
      ([i : i64 0 4])
      (foreach-active
        [n : i64]
        (let
          [k : i64 (lane-value i)]
          (set! (array-ref out k) (+ k n)))))
    (+ (spmd-reduce sum ([i : i64 0 4]) n (array-ref out i)) 0)))

(define (scan-forms [comptime T : type] [comptime n : i64]) : i64
  (let
    [xs : (Array i64 4) (array 1 2 3 4)]
    [prefixes : (Array i64 4) (make-array i64 4)]
    [kept : (Array i64 4) (make-array i64 4)]
    (spmd-scan
      sum
      ([i : i64 0 4] [n : T (cast 0 : T)])
      (cast (array-ref xs i) : T)
      (set! (array-ref prefixes i) (cast n : i64)))
    (spmd-compact
      ([i : i64 0 4] [n : i64 0])
      (> (array-ref xs i) 2)
      (set! (array-ref kept n) (array-ref xs i)))
    (+
      (spmd-reduce sum ([i : i64 0 4]) n (array-ref prefixes i))
      (spmd-reduce sum ([i : i64 0 4]) 0 (array-ref kept i)))))

(define (owned-forms [comptime T : type] [comptime n : i64]) : i64
  (let
    [items : (Array i64 3) (array n 0 (* n 2))]
    [values : i64v.Vec (i64v.new)]
    [total : i64 n]
    (i64v.push! values 4)
    (i64v.push! values n)
    (for [item items] (set! total (+ total (- (cast (cast item : T) : i64) n))))
    (for [n values] (set! total (+ total n)))
    total))

(define (pointer-forms [comptime T : type] [comptime n : i64]) : i64
  (let
    [cell : T (cast n : T)]
    [empty : (Ptr T) (ptr-null : (Ptr T))]
    (unsafe
      (let
        [address : u64 (ptr->int (ptr-addr-of cell))]
        [typed : (Ptr T) (int->ptr address : (Ptr T))]
        [bytes : (Ptr u8) (ptr-cast typed : (Ptr u8))]
        (if (ptr-null? empty)
          (+ (cast (ptr-read typed) : i64) (cast (ptr-read bytes) : i64))
          0)))))

(define (init-forms [comptime T : type] [comptime n : i64]) : i64
  (let
    [zero : T (cast (init : i64) : T)]
    [flag : bool (> n 0)]
    (if flag
      (+ (cast zero : i64) n)
      0)))

(define (nested-forms [comptime T : type] [comptime n : i64]) : i64
  (+ (let-forms (type T) (+ n 1)) (init-forms (type T) n)))

(define (results-ok?
  [lets : i64]
  [lambdas : i64]
  [matches : i64]
  [foreaches : i64]
  [lanes : i64]
  [scans : i64]
  [owned : i64]
  [pointers : i64]
  [nested : i64]) : bool
  (and
    (= lets 12)
    (= lambdas 26)
    (= matches 12)
    (= foreaches 48)
    (= lanes 11)
    (= scans 32)
    (= owned 14)
    (= pointers 10)
    (= nested 19)))

(define (main) : i64
  (if (results-ok?
    (let-forms (type i64) 5)
    (lambda-forms (type i64) 5)
    (match-forms 5)
    (foreach-forms (type i64) 5)
    (lane-forms 5)
    (scan-forms (type i64) 5)
    (owned-forms (type i64) 5)
    (pointer-forms (type i64) 5)
    (nested-forms (type i64) 5))
    42
    1))