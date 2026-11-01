;; `tuple-ref` reads through `&` and `&mut` tuple receivers (#9430): Copy
;; elements copy, and non-Copy elements are views of the referent.
(import stdlib.string)
(import stdlib.test)

(defstruct Point
  (x i64)
  (y i64))

(defstruct Item
  (text String)
  (number i64))

(defenum Shape
  (Dot)
  (Line i64 i64))

(define pair-global : (Tuple i64 i64)
  (tuple 5 6))

(define (first [pair : (& pair (Tuple i64 i64))]) : i64
  (tuple-ref pair 0))

(define (first-mut [pair : (&mut pair (Tuple i64 i64))]) : i64
  (tuple-ref pair 0))

(define (first-deref [pair : (& pair (Tuple i64 i64))]) : i64
  (tuple-ref (deref pair) 0))

(define (first-owned [pair : (Tuple i64 i64)]) : i64
  (tuple-ref pair 0))

(define (nested-last [value : (& value (Tuple (Tuple i64 i64) i64))]) : i64
  (tuple-ref (tuple-ref value 0) 1))

(define (point-y [value : (& value (Tuple Point i64))]) : i64
  (tuple-ref value 0).y)

(define (mixed-sum [value : (& value (Tuple u8 i64 u8))]) : i64
  (+
    (cast (tuple-ref value 0) : i64)
    (tuple-ref value 1)
    (cast (tuple-ref value 2) : i64)))

(define (nothing) : unit
  (begin))

(define (sized-middle [value : (& value (Tuple unit i64 unit))]) : i64
  (begin
    (tuple-ref value 0)
    (tuple-ref value 2)
    (tuple-ref value 1)))

(define (accumulate [pair : (&mut pair (Tuple i64 i64))]) : unit
  (set! (tuple-ref pair 1) (+ (tuple-ref pair 0) (tuple-ref pair 1))))

;; A Copy aggregate element read through `&mut` is a copy: later writes
;; through the reference do not reach it.
(define (copy-then-write [value : (&mut value (Tuple i64 (Tuple i64 i64 i64)))]) : i64
  (let
    [inner : (Tuple i64 i64 i64) (tuple-ref value 1)]
    (set! (tuple-ref (tuple-ref value 1) 2) 99)
    (tuple-ref inner 2)))

(define (text-size [value : (& value (Tuple String String))]) : i64
  (+
    (string.string-length (& (tuple-ref value 0)))
    (string.string-length (tuple-ref value 1))))

(define (starts-hello? [value : (& value (Tuple String i64))]) : bool
  (= (tuple-ref value 0) "hello"))

(define (first-view [value : (& value (Tuple String i64))]) : (& value str)
  (& (tuple-ref value 0)))

(define (item-score [value : (& value (Tuple Item i64))]) : i64
  (+ (tuple-ref value 0).number (string.string-length (tuple-ref value 0).text)))

(define (shape-length [value : (& value (Tuple i64 Shape))]) : i64
  (match (tuple-ref value 1)
    [(Dot) 0]
    [(Line a b) (+ a b)]))

(define (clone-first [value : (& value (Tuple String i64))]) : String
  (clone (tuple-ref value 0)))

(define (replace-first [value : (&mut value (Tuple String i64))]) : String
  (replace! (tuple-ref value 0) "new"))

(define (main) : i64
  (let
    [pair : (Tuple i64 i64) (tuple 42 0)]
    [nested : (Tuple (Tuple i64 i64) i64) (tuple (tuple 1 9) 2)]
    [point : (Tuple Point i64) (tuple (Point 3 11) 4)]
    [mixed : (Tuple u8 i64 u8) (tuple (cast 1 : u8) 40 (cast 2 : u8))]
    [sized : (Tuple unit i64 unit) (tuple (nothing) 13 (nothing))]
    [counter : (Tuple i64 i64) (tuple 40 2)]
    [deep : (Tuple i64 (Tuple i64 i64 i64)) (tuple 0 (tuple 0 0 42))]
    [texts : (Tuple String String) (tuple "hello" "world")]
    [named : (Tuple String i64) (tuple "hello" 1)]
    [item : (Tuple Item i64) (tuple (Item "ab" 10) 0)]
    [shape : (Tuple i64 Shape) (tuple 0 (Line 5 7))]
    [_ (test.assert-i64-eq (first (& pair)) 42 "shared reference")]
    [_ (test.assert-i64-eq (first-mut (&mut pair)) 42 "mutable reference")]
    [local-ref (& pair)]
    [_ (test.assert-i64-eq (tuple-ref local-ref 0) 42 "local reference")]
    [_ (test.assert-i64-eq (first (& pair-global)) 5 "global referent")]
    [_ (test.assert-i64-eq (first-deref (& pair)) 42 "explicit deref control")]
    [_ (test.assert-i64-eq (first-owned pair) 42 "owned tuple control")]
    [_ (test.assert-i64-eq (nested-last (& nested)) 9 "nested tuple")]
    [_ (test.assert-i64-eq (point-y (& point)) 11 "struct element field")]
    [_ (test.assert-i64-eq (mixed-sum (& mixed)) 43 "element offsets")]
    [_ (test.assert-i64-eq (sized-middle (& sized)) 13 "zero-sized elements")]
    [_ (accumulate (&mut counter))]
    [_ (test.assert-i64-eq (tuple-ref counter 1) 42 "read then write")]
    [_ (test.assert-i64-eq (copy-then-write (&mut deep)) 42 "aggregate copy")]
    [_
      (test.assert-i64-eq
        (tuple-ref (tuple-ref deep 1) 2)
        99
        "write reaches referent")]
    [_ (test.assert-i64-eq (text-size (& texts)) 10 "string views")]
    [_ (test.assert-true (starts-hello? (& named)) "string comparison")]
    [_
      (test.assert-i64-eq
        (string.string-length (first-view (& named)))
        5
        "borrowed result")]
    [_ (test.assert-i64-eq (item-score (& item)) 12 "struct element view")]
    [_ (test.assert-i64-eq (shape-length (& shape)) 12 "enum element view")]
    [copied : String (clone-first (& named))]
    [old : String (replace-first (&mut named))]
    (test.assert-i64-eq
      (string.string-length (& copied))
      5
      "clone owns its result")
    (test.assert-i64-eq (string.string-length (& old)) 5 "replacement result")
    (test.assert-true
      (starts-hello? (& (tuple "hello" 0)))
      "temporary referent")
    (test.assert-i64-eq
      (string.string-length (first-view (& named)))
      3
      "replacement reaches referent")
    42))