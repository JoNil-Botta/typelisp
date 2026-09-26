;; replace! returns an old fixed-array element and installs the caller's
;; replacement in the same slot: an owned scalar, a non-Copy String, an
;; aggregate reached through a mutable reference with a runtime index, and a
;; nested element whose indexes are evaluated once, before the replacement.
(import stdlib.string)
(import stdlib.test)

(defstruct Triple
  (a i64)
  (b i64)
  (c i64))

(define evaluation-trace : i64
  0)

(define (mark [digit : i64]) : i64
  (begin
    (set! evaluation-trace (+ (* evaluation-trace 10) digit))
    0))

(define (triple-score [value : Triple]) : i64
  (+ value.a (+ value.b value.c)))

(define (replace-triple [items : (&mut items (Array Triple 2))] [index : i64]) : Triple
  (replace! (array-ref items index) (Triple 4 5 6)))

(define (main) : i64
  (let
    [numbers : (Array i64 3) (array 4 7 9)]
    [triples : (Array Triple 2) (array (Triple 1 2 3) (Triple 8 9 10))]
    [texts : (Array String 2) (array "hello" "later")]
    [nested : (Array (Array i64 1) 1) (array (array 33))]
    [old-number : i64 (replace! (array-ref numbers 1) 0)]
    [old-triple : Triple (replace-triple (&mut triples) 0)]
    [old-text : String (replace! (array-ref texts 0) "")]
    [old-nested : i64
      (replace! (array-ref (array-ref nested (mark 1)) (mark 2)) (mark 3))]
    (begin
      (test.assert-i64-eq old-number 7 "scalar old")
      (test.assert-i64-eq (array-ref numbers 1) 0 "scalar replacement")
      (test.assert-i64-eq (array-ref numbers 0) 4 "scalar left sibling")
      (test.assert-i64-eq (array-ref numbers 2) 9 "scalar right sibling")
      (test.assert-i64-eq (triple-score old-triple) 6 "aggregate old")
      (test.assert-i64-eq
        (triple-score (array-ref triples 0))
        15
        "aggregate replacement")
      (test.assert-i64-eq
        (triple-score (array-ref triples 1))
        27
        "aggregate sibling")
      (test.assert-i64-eq (string.string-length old-text) 5 "String old")
      (test.assert-i64-eq
        (string.string-length (& (array-ref texts 0)))
        0
        "String replacement")
      (test.assert-i64-eq
        (string.string-length (& (array-ref texts 1)))
        5
        "String sibling")
      (test.assert-i64-eq old-nested 33 "nested old")
      (test.assert-i64-eq
        (array-ref (array-ref nested 0) 0)
        0
        "nested replacement")
      (test.assert-i64-eq evaluation-trace 123 "evaluation order")
      42)))