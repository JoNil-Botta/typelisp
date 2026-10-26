;; Borrows of a lambda's captures that the capture rule accepts (#9297). A
;; by-value capture is the lambda's own copy: a borrow of it is used within
;; the call. A captured reference is a copy of the reference, so returning it,
;; or a reborrow through it, keeps the enclosing referent's lifetime. Each case
;; also reads after a call that refills the stack, so a reference into a
;; finished frame would show. `main` yields 42 only if every case does. The
;; lambdas differ in signature or body so opt2 merges none of them (#9317).
(defstruct Pair
  (x i64)
  (y i64))

(define (read-ref [r : (& i64)]) : i64
  (deref r))

;; Fills a frame of its own, as a later call reusing a finished one would.
(define (refill [seed : i64]) : i64
  (let
    [a : (Array i64 32)
      (array 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0)]
    [i : i64 0]
    (while (< i 32)
      (set! (array-ref a i) (+ seed i))
      (set! i (+ i 1)))
    (- (array-ref a 31) (+ seed 31))))

;; A captured reference returned as is, and reborrowed.
(define (case-captured-reference) : i64
  (let
    [x : i64 42]
    [rx : (& x i64) (& x)]
    [f
      (lambda () : (& x i64)
        rx)]
    [g
      (lambda ([_k : bool]) : (& x i64)
        (& (deref rx)))]
    [r : (& x i64) (f)]
    [s : (& x i64) (g true)]
    (+
      (refill 9)
      (if (and (= (deref r) 42) (= (deref s) 42))
        0
        1))))

;; Borrows of a capture used inside the call: lent to a call, bound to a
;; local annotated with a lifetime that names the capture, and in a loop.
(define (case-non-escaping) : i64
  (let
    [x : i64 10]
    [lend
      (lambda () : i64
        (read-ref (& x)))]
    [annotated
      (lambda () : i64
        (let
          [r : (& x i64) (& x)]
          (deref r)))]
    [looped
      (lambda () : i64
        (let
          [i : i64 0]
          [sum : i64 0]
          (while (< i 4)
            (set! sum (+ sum (read-ref (& x))))
            (set! i (+ i 1)))
          sum))]
    (if (and (= (lend) 10) (= (annotated) 10) (= (looped) 40))
      0
      2)))

;; A local or a parameter named like a capture is its own binder.
(define (case-shadowing) : i64
  (let
    [x : i64 1]
    [local
      (lambda () : i64
        (+
          (read-ref (& x))
          (let
            [x : i64 7]
            (read-ref (& x)))))]
    [param
      (lambda ([x : i64]) : i64
        (read-ref (& x)))]
    (if (and (= (local) 8) (= (param 8) 8))
      0
      3)))

;; A nested lambda borrows its capture of a capture within its call, and
;; returns a captured reference out of both lambdas.
(define (case-nested) : i64
  (let
    [x : i64 5]
    [rx : (& x i64) (& x)]
    [outer
      (lambda () : i64
        (let
          [inner
            (lambda ([k : i64]) : i64
              (+ k (read-ref (& x))))]
          (inner 1)))]
    [outer-ref
      (lambda () : (& x i64)
        (let
          [inner
            (lambda ([_k : i64] [_j : i64]) : (& x i64)
              rx)]
          (inner 1 2)))]
    [r : (& x i64) (outer-ref)]
    (+
      (refill 3)
      (if (and (= (outer) 6) (= (deref r) 5))
        0
        4))))

;; Field borrows of a captured register-resident struct, used within the call.
(define (case-fields) : i64
  (let
    [p : Pair (Pair 20 22)]
    [f
      (lambda () : i64
        (+ (read-ref (& p.x)) (read-ref (& p.y))))]
    (if (= (f) 42)
      0
      5)))

(define (main) : i64
  (let
    [failed : i64
      (+
        (case-captured-reference)
        (+
          (case-non-escaping)
          (+ (case-shadowing) (+ (case-nested) (case-fields)))))]
    (if (= failed 0)
      42
      failed)))