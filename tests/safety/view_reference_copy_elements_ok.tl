;; Copy array/tuple elements bind by value through either reference kind.
(define (read-array [r : (& r (Array i64 2))]) : i64
  (let
    [first : i64 (array-ref r 0)]
    [second (array-ref r 1)]
    (+ first second)))

(define (read-mut-array [r : (&mut r (Array i64 2))]) : i64
  (let
    [first : i64 (array-ref r 0)]
    [second (array-ref r 1)]
    (+ first second)))

(define (read-tuple [r : (& r (Tuple i64 i64))]) : i64
  (let
    [first : i64 (tuple-ref r 0)]
    [second (tuple-ref r 1)]
    (+ first second)))

(define (read-mut-tuple [r : (&mut r (Tuple i64 i64))]) : i64
  (let
    [first : i64 (tuple-ref r 0)]
    [second (tuple-ref r 1)]
    (+ first second)))

(define (main) : i64
  (let
    [items : (Array i64 2) (array 5 5)]
    [pair : (Tuple i64 i64) (tuple 5 6)]
    [a : i64 (read-array (& items))]
    [b : i64 (read-mut-array (&mut items))]
    [c : i64 (read-tuple (& pair))]
    [d : i64 (read-mut-tuple (&mut pair))]
    (+ (+ a b) (+ c d))))