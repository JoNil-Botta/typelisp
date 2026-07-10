;; Generated aggregate equality runtime coverage (#4700).
(import stdlib.eq)

(defstruct EqPoint
  (x i64)
  (label String))

(defstruct EqRoute
  (start EqPoint)
  (finish EqPoint))

(defenum EqChoice
  (Empty)
  (Point EqPoint)
  (Pair (Tuple i64 String))
  (Route EqRoute))

(import (eq.eq EqPoint) as point-eq)
(import (eq.eq EqRoute) as route-eq)
(import (eq.eq EqRoute) as route-eq-again)
(import (eq.eq EqChoice) as choice-eq)
(import (eq.eq (Tuple EqPoint (Array i64 2))) as tuple-eq)
(import (eq.eq (Array EqPoint 2)) as point-array-eq)

(define eq-eval-count : i64
  0)

(define (eq-counted-point [x : i64]) : EqPoint
  (begin
    (set! eq-eval-count (+ eq-eval-count 1))
    (EqPoint x "counted")))

(define (main) : i64
  (begin
    (set! eq-eval-count 0)
    (if (and
      (point-eq.eq (EqPoint 4 "north") (EqPoint 4 "north"))
      (not (point-eq.eq (EqPoint 4 "north") (EqPoint 5 "north")))
      (route-eq.eq
        (EqRoute (EqPoint 1 "a") (EqPoint 2 "b"))
        (EqRoute (EqPoint 1 "a") (EqPoint 2 "b")))
      (route-eq-again.eq?
        (EqRoute (EqPoint 3 "c") (EqPoint 4 "d"))
        (EqRoute (EqPoint 3 "c") (EqPoint 4 "d")))
      (not
        (route-eq.eq
          (EqRoute (EqPoint 1 "a") (EqPoint 2 "b"))
          (EqRoute (EqPoint 1 "a") (EqPoint 9 "b"))))
      (choice-eq.eq
        (EqChoice.Point (EqPoint 7 "seven"))
        (EqChoice.Point (EqPoint 7 "seven")))
      (choice-eq.eq?
        (EqChoice.Pair (tuple 8 "eight"))
        (EqChoice.Pair (tuple 8 "eight")))
      (not
        (choice-eq.eq
          (EqChoice.Point (EqPoint 7 "seven"))
          (EqChoice.Point (EqPoint 7 "other"))))
      (not (choice-eq.eq (EqChoice.Empty) (EqChoice.Point (EqPoint 0 "zero"))))
      (choice-eq.eq
        (EqChoice.Route (EqRoute (EqPoint 1 "a") (EqPoint 2 "b")))
        (EqChoice.Route (EqRoute (EqPoint 1 "a") (EqPoint 2 "b"))))
      (tuple-eq.eq
        (tuple (EqPoint 1 "one") (array 4 5))
        (tuple (EqPoint 1 "one") (array 4 5)))
      (not
        (tuple-eq.eq?
          (tuple (EqPoint 1 "one") (array 4 5))
          (tuple (EqPoint 1 "one") (array 5 4))))
      (point-array-eq.eq
        (array (EqPoint 1 "one") (EqPoint 2 "two"))
        (array (EqPoint 1 "one") (EqPoint 2 "two")))
      (not
        (point-array-eq.eq?
          (array (EqPoint 1 "one") (EqPoint 2 "two"))
          (array (EqPoint 1 "one") (EqPoint 3 "three"))))
      (point-eq.eq (eq-counted-point 12) (eq-counted-point 12))
      (= eq-eval-count 2))
      42
      1)))