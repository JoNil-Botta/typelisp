;; Observations of borrowed fixed-array places do not transfer their elements.
(import stdlib.string)
(import stdlib.test)

(defstruct Triple
  (x i64)
  (y i64)
  (z i64))

(defstruct Item
  (text String)
  (number i64))

(define (sum [items : (& (Array i64 2))]) : i64
  (+ (array-ref items 0) (array-ref items 1)))

(define (copy-triple [items : (& (Array Triple 1))]) : Triple
  (array-ref items 0))

(define (number [items : (& (Array Item 2))]) : i64
  (array-ref items 0).number)

(define (text-size [items : (& (Array String 2))]) : i64
  (+
    (string.string-length (& (array-ref items 0)))
    (string.string-length (array-ref items 1))))

(define (starts-hello? [items : (& (Array String 2))]) : bool
  (= (array-ref items 0) "hello"))

(define (first-view [items : (& items (Array String 2))]) : (& items str)
  (& (array-ref items 0)))

(define (width [items : (& (Array (Array String 2) 1))]) : i64
  (array-length (array-ref items 0)))

(define (change-nested [items : (&mut (Array (Array String 2) 1))]) : unit
  (set! (array-ref (array-ref items 0) 1) "longer"))

(define (replace-first [items : (&mut (Array String 2))]) : String
  (replace! (array-ref items 0) "new"))

(define (move-owned [items : (Array String 2)]) : String
  (array-ref items 0))

(define (touch [value : (&mut i64)]) : unit
  (set! (deref value) 7))

(define (touch-reference [items : (Array (&mut i64) 1)]) : unit
  (touch (array-ref items 0)))

(define (main) : i64
  (let
    [numbers : (Array i64 2) (array 4 8)]
    [triples : (Array Triple 1) (array (Triple 1 2 3))]
    [items : (Array Item 2) (array (Item "a" 11) (Item "bb" 12))]
    [texts : (Array String 2) (array "hello" "world")]
    [nested : (Array (Array String 2) 1) (array (array "aa" "bbb"))]
    [triple : Triple (copy-triple (& triples))]
    [_ (test.assert-i64-eq (sum (& numbers)) 12 "Copy elements")]
    [_ (test.assert-i64-eq (+ triple.x triple.y triple.z) 6 "Copy aggregate")]
    [_
      (test.assert-i64-eq
        (number (& items))
        11
        "Copy field of borrowed element")]
    [_
      (test.assert-i64-eq
        (text-size (& texts))
        10
        "explicit and implicit borrows")]
    [_
      (test.assert-true (starts-hello? (& texts)) "string comparison observes")]
    [_ (test.assert-i64-eq (width (& nested)) 2 "length observes nested array")]
    [_ (change-nested (&mut nested))]
    [old : String (replace-first (&mut texts))]
    [moved : String (move-owned (array "x" "yy"))]
    (test.assert-i64-eq
      (string.string-length (& old))
      5
      "replacement returns old owner")
    (test.assert-i64-eq
      (string.string-length (first-view (& texts)))
      3
      "borrowed result")
    (test.assert-i64-eq
      (string.string-length (& (array-ref (array-ref nested 0) 1)))
      6
      "nested mutable receiver")
    (test.assert-i64-eq
      (string.string-length (& moved))
      1
      "owned element can move")
    (let
      [counter : (Array i64 2) (array 0 19)]
      [references (array (&mut (array-ref counter 0)))]
      (touch-reference references)
      (test.assert-i64-eq
        (array-ref counter 0)
        7
        "mutable-reference element is reborrowed")
      (test.assert-i64-eq
        (array-ref counter 1)
        19
        "element reborrow preserves its neighbor"))
    42))