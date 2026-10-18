;; Caller-owned references keep their lifetime through every kind of storage,
;; even when a parameter has the lifetime's name.
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(defstruct PairBox
  (:lifetimes a)
  (pair (Tuple (& a i64) i64)))

(defstruct BoxBox
  (:lifetimes a)
  (boxed (Box (& a i64))))

(define (store-whole [a : i64] [p : (& a i64)] [b : (&mut a (RefBox a))]) : unit
  (set! (deref b) (RefBox p)))

(define (store-tuple [a : i64] [p : (& a i64)] [b : (&mut a (PairBox a))]) : unit
  (set! b.pair (tuple p a)))

(define (store-box [a : i64] [p : (& a i64)] [b : (&mut a (BoxBox a))]) : unit
  (set! b.boxed (box p)))

(defstruct Outer
  (:lifetimes a)
  (inner (RefBox a)))

(define (store-nested [a : i64] [p : (& a i64)] [b : (&mut a (Outer a))]) : unit
  (set! (deref b) (Outer (RefBox p))))

(define (store-slice
  [a : i64]
  [p : (& a i64)]
  [items : (&mut r (Slice (& a i64)))]) : unit
  (set! (array-ref items 0) p))

(define (store-local [xs : (& a (Array i64 2))]) : i64
  (let
    [a : i64 0]
    [rb (RefBox (& a))]
    (set! rb.value (& (array-ref xs 0)))
    (deref rb.value)))

(define (pass [a : i64] [p : (& a i64)]) : (& a i64)
  p)

(define (main) : i64
  0)