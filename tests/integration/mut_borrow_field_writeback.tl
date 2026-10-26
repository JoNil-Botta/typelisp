;; Call-scoped mutable field borrows copy back only their selected byte range.
;; Sibling writebacks and later argument effects must survive that merge.
(defstruct One
  (x i64))

(defstruct Pair
  (x i64)
  (y i64))

(defstruct Small
  (x i32)
  (y i32))

(defstruct Nested
  (inner Small)
  (tail i64))

(defstruct Floats
  (x f64)
  (y f64))

(defstruct Wide
  (x i64)
  (y i64)
  (z i64))

(define events : i64
  0)

(define (bump! [value : (&mut v i64)]) : unit
  (set! (deref value) (+ (deref value) 4)))

(define (read [value : (& v i64)]) : i64
  (deref value))

(define (write-two! [x : (&mut x i64)] [y : (&mut y i64)]) : unit
  (set! (deref x) (+ (deref x) 4))
  (set! (deref y) (+ (deref y) 7)))

(define (write-small! [x : (&mut x i32)] [y : (&mut y i32)]) : unit
  (set! (deref x) (+ (deref x) (cast 4 : i32)))
  (set! (deref y) (+ (deref y) (cast 7 : i32))))

(define (bump-small! [x : (&mut x i32)] [_note : i64]) : i64
  (set! events (+ (* events 10) 3))
  (set! (deref x) (+ (deref x) (cast 4 : i32)))
  17)

(define (bump-noted! [x : (&mut x i64)] [_first : i64] [_second : i64]) : i64
  (set! events (+ (* events 10) 3))
  (bump! x)
  17)

(define (bump-float! [x : (&mut x f64)]) : unit
  (set! (deref x) (+ (deref x) 1.5)))

(define (bump-pair! [p : (&mut p Pair)]) : unit
  (set! p.x (+ p.x 4))
  (set! p.y (+ p.y 7)))

(define (one-field) : bool
  (let
    [p : One (One 1)]
    (bump! (&mut p.x))
    (= p.x 5)))

(define (two-fields) : bool
  (let
    [p : Pair (Pair 1 2)]
    (bump! (&mut p.x))
    (bump! (&mut p.y))
    (and (= p.x 5) (= p.y 6))))

(define (shared-control) : bool
  (let
    [p : Pair (Pair 1 2)]
    [x : i64 (read (& p.x))]
    [y : i64 (read (& p.y))]
    (and (= x 1) (= y 2) (= p.x 1) (= p.y 2))))

(define (sibling-arguments) : bool
  (let
    [p : Pair (Pair 1 2)]
    (write-two! (&mut p.x) (&mut p.y))
    (and (= p.x 5) (= p.y 9))))

(define (same-word-siblings) : bool
  (let
    [p : Small (Small -1 2)]
    (write-small! (&mut p.x) (&mut p.y))
    (and (= p.x 3) (= p.y 9))))

(define (nested-siblings) : bool
  (let
    [p : Nested (Nested (Small 1 2) 30)]
    (write-small! (&mut p.inner.x) (&mut p.inner.y))
    (bump! (&mut p.tail))
    (and (= p.inner.x 5) (= p.inner.y 9) (= p.tail 34))))

(define (later-sibling-effects) : bool
  (let
    [p : Pair (Pair 1 2)]
    (set! events 0)
    (let
      [result : i64
        (bump-noted!
          (&mut p.x)
          (begin
            (set! events (+ (* events 10) 1))
            (set! p.y 20)
            0)
          (begin
            (set! events (+ (* events 10) 2))
            (bump! (&mut p.y))
            0))]
      (and (= p.x 5) (= p.y 24) (= result 17) (= events 123)))))

(define (nested-later-sibling-effects) : bool
  (let
    [p : Nested (Nested (Small 1 2) 30)]
    (set! events 1)
    (let
      [result : i64
        (bump-small!
          (&mut p.inner.x)
          (begin
            (set! events (+ (* events 10) 2))
            (set! p.inner.y 20)
            (set! p.tail 40)
            0))]
      (and
        (= p.inner.x 5)
        (= p.inner.y 20)
        (= p.tail 40)
        (= result 17)
        (= events 123)))))

(define (repeated-calls) : bool
  (let
    [p : Pair (Pair 1 2)]
    [index : i64 0]
    (while (< index 3)
      (write-two! (&mut p.x) (&mut p.y))
      (+= index 1))
    (and (= p.x 13) (= p.y 23))))

(define (float-fields) : bool
  (let
    [p : Floats (Floats 0.5 2.5)]
    (bump-float! (&mut p.x))
    (bump-float! (&mut p.y))
    (and (= p.x 2.0) (= p.y 4.0))))

(define (memory-backed) : bool
  (let
    [p : Wide (Wide 1 2 3)]
    (write-two! (&mut p.x) (&mut p.y))
    (bump! (&mut p.z))
    (and (= p.x 5) (= p.y 9) (= p.z 7))))

(define (borrowed-receiver [p : (&mut p Pair)]) : bool
  (write-two! (&mut p.x) (&mut p.y))
  (and (= p.x 5) (= p.y 9)))

(define (whole-local-control) : bool
  (let
    [p : Pair (Pair 1 2)]
    [scalar : i64 1]
    (bump-pair! (&mut p))
    (bump! (&mut scalar))
    (and (= p.x 5) (= p.y 9) (= scalar 5))))

(define (main) : i64
  (let
    [borrowed : Pair (Pair 1 2)]
    (cond
      [(not (one-field)) 1]
      [(not (two-fields)) 2]
      [(not (shared-control)) 3]
      [(not (sibling-arguments)) 4]
      [(not (same-word-siblings)) 5]
      [(not (nested-siblings)) 6]
      [(not (later-sibling-effects)) 7]
      [(not (nested-later-sibling-effects)) 8]
      [(not (repeated-calls)) 9]
      [(not (float-fields)) 10]
      [(not (memory-backed)) 11]
      [(not (borrowed-receiver (&mut borrowed))) 12]
      [(not (whole-local-control)) 13]
      [else 42])))