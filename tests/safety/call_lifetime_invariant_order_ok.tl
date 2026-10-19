(defstruct RefBox
  (:lifetimes t)
  (value (& t i64)))

(define (put [value : (& t i64)] [target : (&mut r (RefBox t))]) : i64
  (set! target.value value)
  (deref target.value))

(define (put-swapped [target : (&mut r (RefBox t))] [value : (& t i64)]) : i64
  (set! target.value value)
  (deref target.value))

(define (put-surrounded
  [before : (& t i64)]
  [target : (&mut r (RefBox t))]
  [after : (& t i64)]) : i64
  (set! target.value before)
  (set! target.value after)
  (deref target.value))

(define (put-pair
  [value : (& t i64)]
  [first : (&mut r (RefBox t))]
  [second : (&mut s (RefBox t))]) : i64
  (set! first.value value)
  (set! second.value value)
  (+ (deref first.value) (deref second.value)))

;; Covariant caller references may shorten to the invariant local box lifetime.
(define (value-first [xs : (& a (Array i64 2))]) : i64
  (let
    [local : i64 7]
    [holder (RefBox (& local))]
    (put (& (array-ref xs 0)) (&mut holder))
    (deref holder.value)))

(define (box-first [xs : (& a (Array i64 2))]) : i64
  (let
    [local : i64 7]
    [holder (RefBox (& local))]
    (put-swapped (&mut holder) (& (array-ref xs 0)))
    (deref holder.value)))

(define (surrounded [xs : (& a (Array i64 2))]) : i64
  (let
    [local : i64 7]
    [holder (RefBox (& local))]
    (put-surrounded (& (array-ref xs 0)) (&mut holder) (& (array-ref xs 1)))
    (deref holder.value)))

(define (repeated [xs : (& a (Array i64 2))]) : i64
  (let
    [local : i64 7]
    [first (RefBox (& local))]
    [second (RefBox (& local))]
    (put-pair (& (array-ref xs 0)) (&mut first) (&mut second))
    (+ (deref first.value) (deref second.value))))

(define (main) : i64
  (let
    [xs : (Array i64 2) (array 35 42)]
    (if (and
      (= (value-first (& xs)) 35)
      (= (box-first (& xs)) 35)
      (= (surrounded (& xs)) 42)
      (= (repeated (& xs)) 70))
      42
      1)))