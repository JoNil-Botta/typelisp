;; A global initialized from another global holds that global's value, not its
;; address (#7804). Every initializer below names another global, directly or
;; through `ann`, `cast`, an import, a chain or a later declaration. The
;; function-valued globals keep their closure-descriptor initializers. main
;; returns 42 when every value matches, and otherwise the number of the first
;; mismatch.
(import global_reference_initializer_dep as dep)

(defstruct Point
  (x i64)
  (y i64))

(defenum Color
  (Red)
  (Green)
  (Blue))

(define (inc [x : i64]) : i64
  (+ x 1))

(define (dec [x : i64]) : i64
  (- x 1))

(define (color-code [c : Color]) : i64
  (match c
    [(Red) 1]
    [(Green) 2]
    [(Blue) 3]))

(define base : i64
  14)
(define copy : i64
  base)
(define inferred
  base)
(define chain-one : i64
  base)
(define chain-two : i64
  chain-one)
(define chain-three : i64
  chain-two)
(define annotated : i64
  (ann base : i64))
(define small : i32
  -5)
(define widened : i64
  (cast small : i64))
(define narrow-copy : i32
  small)
(define byte : u8
  250)
(define byte-copy : u8
  byte)
(define ratio : f64
  2.5)
(define ratio-copy : f64
  ratio)
(define enabled : bool
  true)
(define enabled-copy : bool
  enabled)
(define early : i64
  later)
(define later : i64
  5)
(define computed : i64
  (+ 40 2))
(define computed-copy : i64
  computed)
(define imported : i64
  dep.answer)
(define imported-flag : bool
  dep.flag)
(define imported-computed : i64
  dep.computed)
(define origin : Point
  (Point 20 22))
(define origin-copy : Point
  origin)
(define color : Color
  Green)
(define qualified-color : Color
  Color.Blue)
(define callback : (-> i64 i64)
  inc)
(define callback-copy : (-> i64 i64)
  callback)

(define (check [index : i64] [ok : bool] [first-failure : i64]) : i64
  (if (or ok (not (= first-failure 0)))
    first-failure
    index))

(define (main) : i64
  (begin
    ;; Mutations after initialization must not reach the copies.
    (set! base 99)
    (dep.set-answer! 99)
    (set! callback dec)
    (let
      [failure : i64 0]
      (begin
        (set! failure (check 1 (= copy 14) failure))
        (set! failure (check 2 (= inferred 14) failure))
        (set! failure (check 3 (= chain-three 14) failure))
        (set! failure (check 4 (= annotated 14) failure))
        (set! failure (check 5 (= widened -5) failure))
        (set! failure (check 6 (= narrow-copy -5) failure))
        (set! failure (check 7 (= byte-copy 250) failure))
        (set! failure (check 8 (= ratio-copy 2.5) failure))
        (set! failure (check 9 enabled-copy failure))
        (set! failure (check 10 (= early 5) failure))
        (set! failure (check 11 (= computed-copy 42) failure))
        (set! failure (check 12 (= imported 14) failure))
        (set! failure (check 13 imported-flag failure))
        (set! failure (check 14 (= imported-computed 21) failure))
        (set! failure (check 15 (= (+ origin-copy.x origin-copy.y) 42) failure))
        (set! failure (check 16 (= (color-code color) 2) failure))
        (set! failure (check 17 (= (color-code qualified-color) 3) failure))
        (set! failure (check 18 (= (callback-copy 41) 42) failure))
        (set! failure (check 19 (= (callback 43) 42) failure))
        (set! failure (check 20 (= base 99) failure))
        (set! failure (check 21 (= dep.answer 99) failure))
        (if (= failure 0)
          42
          failure)))))