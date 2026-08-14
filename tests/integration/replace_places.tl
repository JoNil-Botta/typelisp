;; replace! evaluates a normalized mutable place once, returns its old value,
;; and leaves the replacement initialized in that same storage.
(import stdlib.string)
(import stdlib.test)
(import stdlib.comptime)

(defmacro (generated-replace! [place : Expr] [replacement : Expr]) : Expr
  (comptime.expr-replace place replacement))

(defstruct Pair
  (left i64)
  (right i64))

(defstruct Nested
  (pair Pair))

(defstruct OwnedPair
  (left (Box i64))
  (right (Box i64)))

(define evaluation-trace : i64
  0)
(define global-counter : i64
  40)

(define (mark-place [digit : i64]) : i64
  (begin
    (set! evaluation-trace (+ (* evaluation-trace 10) digit))
    0))

(define (mark-replacement [value : i64]) : i64
  (begin
    (set! evaluation-trace (+ (* evaluation-trace 10) 2))
    value))

(define (replace-through-mut [value : (&mut value i64)]) : i64
  (replace! (deref value) 17))

(define (replace-slice [items : (&mut items (Slice i64))]) : i64
  (replace! (array-ref items 1) 15))

(define compile-score : i64
  (comptime
    (let
      [value : i64 4]
      (+ (* (replace! value 9) 10) value))))

(define (pair-score [value : Pair]) : i64
  (+ value.left value.right))

(define (main) : i64
  (let
    [scalar : i64 4]
    [old-scalar : i64 (replace! scalar (+ scalar 1))]
    [generated : i64 30]
    [old-generated : i64 (generated-replace! generated 31)]
    [text : String "hello"]
    [old-text : String
      (replace!
        text
        (if (= (string.string-length (& text)) 5)
          "new"
          "bad"))]
    [boxed : (Box i64) (box 11)]
    [old-inner : i64 (replace! (deref boxed) 12)]
    [owner : (Box i64) (box 20)]
    [old-owner : (Box i64) (replace! owner (box 21))]
    [pair : Pair (Pair 1 2)]
    [old-field : i64 (replace! pair.left 8)]
    [tuple-value : (Tuple i64 i64) (tuple 3 4)]
    [old-tuple : i64 (replace! (tuple-ref tuple-value 0) 9)]
    [items : (Array i64 2) (array 10 20)]
    [runtime-index : i64 1]
    [old-item : i64 (replace! (array-ref items runtime-index) 30)]
    [nested : Nested (Nested (Pair 5 6))]
    [old-nested : Pair (replace! nested.pair (Pair 7 8))]
    [slice-items : (Array i64 2) (array 13 14)]
    [old-slice : i64 (replace-slice (&mut slice-items))]
    [ref-target : i64 16]
    [old-ref : i64 (replace-through-mut (&mut ref-target))]
    [order-items : (Array i64 1) (array 18)]
    [old-order : i64
      (replace! (array-ref order-items (mark-place 1)) (mark-replacement 19))]
    [partial : OwnedPair (OwnedPair (box 22) (box 23))]
    [moved-left : (Box i64) partial.left]
    [old-right : (Box i64) (replace! partial.right (box 24))]
    [disjoint : OwnedPair (OwnedPair (box 25) (box 26))]
    [old-disjoint-right : (Box i64) (replace! disjoint.right disjoint.left)]
    [old-global : i64 (replace! global-counter 41)]
    (begin
      (test.assert-i64-eq compile-score 49 "comptime replace")
      (test.assert-i64-eq old-scalar 4 "scalar old")
      (test.assert-i64-eq scalar 5 "scalar replacement")
      (test.assert-i64-eq old-generated 30 "macro-generated old")
      (test.assert-i64-eq generated 31 "macro-generated replacement")
      (test.assert-i64-eq (string.string-length old-text) 5 "String old")
      (test.assert-i64-eq (string.string-length text) 3 "String replacement")
      (test.assert-i64-eq old-inner 11 "Box inner old")
      (test.assert-i64-eq (deref boxed) 12 "Box inner replacement")
      (test.assert-i64-eq (deref old-owner) 20 "Box owner old")
      (test.assert-i64-eq (deref owner) 21 "Box owner replacement")
      (test.assert-i64-eq old-field 1 "field old")
      (test.assert-i64-eq (pair-score pair) 10 "field replacement")
      (test.assert-i64-eq old-tuple 3 "tuple old")
      (test.assert-i64-eq (tuple-ref tuple-value 0) 9 "tuple replacement")
      (test.assert-i64-eq (tuple-ref tuple-value 1) 4 "tuple sibling")
      (test.assert-i64-eq old-item 20 "array old")
      (test.assert-i64-eq (array-ref items 0) 10 "array sibling")
      (test.assert-i64-eq (array-ref items 1) 30 "array replacement")
      (test.assert-i64-eq (pair-score old-nested) 11 "aggregate old")
      (test.assert-i64-eq (pair-score nested.pair) 15 "aggregate replacement")
      (test.assert-i64-eq old-slice 14 "Slice old")
      (test.assert-i64-eq (array-ref slice-items 1) 15 "Slice replacement")
      (test.assert-i64-eq old-ref 16 "mutable ref old")
      (test.assert-i64-eq ref-target 17 "mutable ref replacement")
      (test.assert-i64-eq old-order 18 "ordered old")
      (test.assert-i64-eq (array-ref order-items 0) 19 "ordered replacement")
      (test.assert-i64-eq evaluation-trace 12 "evaluation order")
      (test.assert-i64-eq (deref moved-left) 22 "partial moved sibling")
      (test.assert-i64-eq (deref old-right) 23 "partial field old")
      (test.assert-i64-eq (deref partial.right) 24 "partial field replacement")
      (test.assert-i64-eq (deref old-disjoint-right) 26 "disjoint move old")
      (test.assert-i64-eq (deref disjoint.right) 25 "disjoint move replacement")
      (test.assert-i64-eq old-global 40 "Copy global old")
      (test.assert-i64-eq global-counter 41 "Copy global replacement")
      42)))