;; stdlib_eq.tl - generated scalar and aggregate equality modules (#3868, #4700).
(import stdlib.test)
(import stdlib.eq)
(import (eq.eq i64) as i64-eq)
(import (eq.eq i64) as i64-eq-again)
(import (eq.eq u8) as u8-eq)
(import (eq.eq (type unit)) as unit-eq)
(import (eq.eq String) as string-eq)

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

(test
  stdlib-eq-generated-scalar-modules
  (begin
    (test.assert-true (i64-eq.eq 42 42) "i64 equality succeeds")
    (test.assert-false (i64-eq.eq? 42 7) "i64 equality detects mismatch")
    (test.assert-true (i64-eq-again.eq? 9 9) "duplicate i64 import succeeds")
    (test.assert-true (u8-eq.eq 7 7) "u8 equality succeeds")
    (test.assert-true (unit-eq.eq unit unit) "unit equality succeeds")
    (test.assert-true (string-eq.eq "same" "same") "string equality succeeds")
    (test.assert-false
      (string-eq.eq? "left" "right")
      "string equality detects mismatch")))

(test
  stdlib-eq-generated-struct-modules
  (begin
    (test.assert-true
      (point-eq.eq (EqPoint 4 "north") (EqPoint 4 "north"))
      "struct equality compares scalar and String fields")
    (test.assert-false
      (point-eq.eq (EqPoint 4 "north") (EqPoint 5 "north"))
      "struct equality detects a scalar field mismatch")
    (test.assert-false
      (point-eq.eq? (EqPoint 4 "north") (EqPoint 4 "south"))
      "struct equality detects a nested String mismatch")
    (test.assert-true
      (route-eq.eq
        (EqRoute (EqPoint 1 "a") (EqPoint 2 "b"))
        (EqRoute (EqPoint 1 "a") (EqPoint 2 "b")))
      "struct equality recurses into nested structs")
    (test.assert-true
      (route-eq-again.eq?
        (EqRoute (EqPoint 3 "c") (EqPoint 4 "d"))
        (EqRoute (EqPoint 3 "c") (EqPoint 4 "d")))
      "repeated aggregate imports reuse the generated module")
    (test.assert-false
      (route-eq.eq
        (EqRoute (EqPoint 1 "a") (EqPoint 2 "b"))
        (EqRoute (EqPoint 1 "a") (EqPoint 9 "b")))
      "nested struct equality detects a leaf mismatch")))

(test
  stdlib-eq-generated-enum-modules
  (begin
    (test.assert-true
      (choice-eq.eq
        (EqChoice.Point (EqPoint 7 "seven"))
        (EqChoice.Point (EqPoint 7 "seven")))
      "enum equality compares aggregate payloads")
    (test.assert-true
      (choice-eq.eq?
        (EqChoice.Pair (tuple 8 "eight"))
        (EqChoice.Pair (tuple 8 "eight")))
      "enum equality compares tuple payloads")
    (test.assert-false
      (choice-eq.eq
        (EqChoice.Point (EqPoint 7 "seven"))
        (EqChoice.Point (EqPoint 7 "other")))
      "enum equality detects payload mismatches")
    (test.assert-false
      (choice-eq.eq (EqChoice.Empty) (EqChoice.Point (EqPoint 0 "zero")))
      "enum equality rejects differing variants")
    (test.assert-true
      (choice-eq.eq
        (EqChoice.Route (EqRoute (EqPoint 1 "a") (EqPoint 2 "b")))
        (EqChoice.Route (EqRoute (EqPoint 1 "a") (EqPoint 2 "b"))))
      "enum equality recurses through nested structs")))

(test
  stdlib-eq-generated-tuple-and-fixed-array-modules
  (begin
    (test.assert-true
      (tuple-eq.eq
        (tuple (EqPoint 1 "one") (array 4 5))
        (tuple (EqPoint 1 "one") (array 4 5)))
      "tuple equality compares nested structs and fixed arrays in order")
    (test.assert-false
      (tuple-eq.eq?
        (tuple (EqPoint 1 "one") (array 4 5))
        (tuple (EqPoint 1 "one") (array 5 4)))
      "tuple equality detects ordered array mismatches")
    (test.assert-true
      (point-array-eq.eq
        (array (EqPoint 1 "one") (EqPoint 2 "two"))
        (array (EqPoint 1 "one") (EqPoint 2 "two")))
      "fixed-array equality compares nested aggregate elements")
    (test.assert-false
      (point-array-eq.eq?
        (array (EqPoint 1 "one") (EqPoint 2 "two"))
        (array (EqPoint 1 "one") (EqPoint 3 "three")))
      "fixed-array equality detects element mismatches")))

(test
  stdlib-eq-generated-arguments-evaluate-once
  (begin
    (set! eq-eval-count 0)
    (test.assert-true
      (point-eq.eq (eq-counted-point 12) (eq-counted-point 12))
      "aggregate equality returns true for equal computed operands")
    (test.assert-i64-eq
      eq-eval-count
      2
      "aggregate equality evaluates each call operand exactly once")))