;; A caller reference and a borrow of a local spelled like its lifetime mix
;; wherever the local's shorter lifetime is expected: assignments, `replace!`,
;; constructors, array literals, tuples, typed `for` items and `ann`, also for
;; values read through a caller reference.
(defstruct RefBox
  (:lifetimes t)
  (value (& t i64)))

(defstruct Pair
  (:lifetimes t)
  (left (& t i64))
  (right (& t i64)))

(defstruct Outer
  (:lifetimes t)
  (inner (RefBox t)))

(define (assign [xs : (& a (Array i64 2))]) : i64
  (let
    [a : i64 0]
    [r (& a)]
    (set! r (& (array-ref xs 0)))
    (deref r)))

(define (pair [xs : (& a (Array i64 2))]) : i64
  (let
    [a : i64 0]
    [p (Pair (& a) (& (array-ref xs 0)))]
    (deref p.right)))

(define (both [xs : (& a (Array i64 2))]) : i64
  (let
    [a : i64 0]
    [rs (array (& a) (& (array-ref xs 0)))]
    (deref (array-ref rs 1))))

(define (tup [xs : (& a (Array i64 2))]) : i64
  (let
    [a : i64 0]
    [t (tuple (& a) 0)]
    (set! t (tuple (& (array-ref xs 0)) 1))
    (deref (tuple-ref t 0))))

(define (nested [a : i64] [p : (& a i64)]) : i64
  (let
    [x : i64 1]
    [q
      (let
        [y : i64 2]
        [r : (& y i64) (& x)]
        r)]
    (deref q)))

(define (annotated [a : i64] [p : (& a i64)]) : i64
  (let
    [q
      (let
        [y : i64 2]
        [r : (& y i64) (& (deref p))]
        r)]
    (+ a (deref q))))

(define (typed-item [arr : (& a (Array i64 4))]) : i64
  (let
    [a : i64 0]
    [total : i64 a]
    (for [x : (& a i64) arr]
      (set! total (+ total (deref x))))
    total))

(define (annotated-field [p : (& t (Outer t))]) : i64
  (let
    [t : i64 1]
    [v (ann p.inner : (RefBox t))]
    (+ t (deref v.value))))

(define (assign-field [p : (& t (Outer t))]) : i64
  (let
    [t : i64 1]
    [rb (RefBox (& t))]
    (set! rb p.inner)
    (+ t (deref rb.value))))

(define (replace-field [p : (& t (Outer t))]) : i64
  (let
    [t : i64 1]
    [rb (RefBox (& t))]
    [old (replace! rb p.inner)]
    (+ (deref old.value) (deref rb.value))))

(define (main) : i64
  0)