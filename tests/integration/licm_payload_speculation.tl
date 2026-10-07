;; #8124: LICM must not speculate a checked-pointer load of an enum payload word
;; ahead of the match arm that tests the tag. Each loop matches a
;; runtime-selected variant in a branch the first trips may skip, so the payload
;; read is loop-invariant but does not run on every entry. Under the other
;; variant the payload word is an integer or was never written, and reading
;; through it as a handle faults. Argument 1 picks the handle-carrying variant
;; (1) or the other one (0); the loops add from trip argument 2 on. Exits 42
;; when every loop counts correctly.
(import stdlib.io)
(import stdlib.string)

(defstruct Holder
  (xs (__tl_dyn-array i64)))

(defenum Val
  (Num i64)
  (Hold Holder))

;; A nullary variant is its tag alone, so `None`'s payload word is never written.
;; The handle sits in a struct payload: a dynamic array bound directly through
;; an enum reference is #8119.
(defenum MaybeArray
  (None)
  (Some Holder))

(defstruct Wrap
  (tag i64)
  (val Val))

(define (make-val [pick : i64]) : Val
  (if (= pick 1)
    (Val.Hold (Holder (__tl_make-array i64 4)))
    (Val.Num 12345)))

(define (make-maybe [pick : i64]) : MaybeArray
  (if (= pick 1)
    (MaybeArray.Some (Holder (__tl_make-array i64 4)))
    (MaybeArray.None)))

(define (sum-val [x : (& Val)] [first : i64]) : i64
  (let
    [i : i64 0]
    [sum : i64 0]
    (while (< i 10)
      (when
        (>= i first)
        (match x
          [(Val.Hold h) (set! sum (+ sum (array-length h.xs)))]
          [(Val.Num _) (set! sum (+ sum 1))]))
      (set! i (+ i 1)))
    sum))

(define (sum-maybe [m : (& MaybeArray)] [first : i64]) : i64
  (let
    [i : i64 0]
    [sum : i64 0]
    (while (< i 10)
      (when
        (>= i first)
        (match m
          [(MaybeArray.Some h) (set! sum (+ sum (array-length h.xs)))]
          [(MaybeArray.None) (set! sum (+ sum 1))]))
      (set! i (+ i 1)))
    sum))

;; The enum sits inline in a struct, behind a reference parameter.
(define (sum-wrap [w : (& Wrap)] [first : i64]) : i64
  (let
    [i : i64 0]
    [sum : i64 0]
    (while (< i 10)
      (when
        (>= i first)
        (match w.val
          [(Val.Hold h) (set! sum (+ sum (array-length h.xs)))]
          [(Val.Num _) (set! sum (+ sum 1))]))
      (set! i (+ i 1)))
    sum))

;; The same struct as a frame object of the looping function.
(define (sum-local-wrap [pick : i64] [first : i64]) : i64
  (let
    [w : Wrap (Wrap 7 (make-val pick))]
    [i : i64 0]
    [sum : i64 0]
    (while (< i 10)
      (when
        (>= i first)
        (match w.val
          [(Val.Hold h) (set! sum (+ sum (array-length h.xs)))]
          [(Val.Num _) (set! sum (+ sum 1))]))
      (set! i (+ i 1)))
    sum))

(define (expected [pick : i64] [first : i64]) : i64
  (let
    [trips : i64
      (if (>= first 10)
        0
        (- 10 first))]
    (if (= pick 1)
      (* trips 4)
      trips)))

(define (main) : i64
  (let
    [pick : i64 (string.>int (io.arg 1))]
    [first : i64 (string.>int (io.arg 2))]
    [want : i64 (expected pick first)]
    [v : Val
      (if (= pick 1)
        (Val.Hold (Holder (__tl_make-array i64 4)))
        (Val.Num (+ pick 12345)))]
    [m : MaybeArray (make-maybe pick)]
    [w : Wrap (Wrap 3 (make-val pick))]
    (cond
      [(not (= (sum-val (& v) first) want)) 1]
      [(not (= (sum-maybe (& m) first) want)) 2]
      [(not (= (sum-wrap (& w) first) want)) 3]
      [(not (= (sum-local-wrap pick first) want)) 4]
      [else 42])))