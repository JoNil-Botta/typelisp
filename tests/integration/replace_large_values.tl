;; Memory-class values are snapshotted into independent result storage before
;; the replacement is committed.
(import stdlib.test)

(defstruct Large
  (a i64)
  (b i64)
  (c i64)
  (d i64)
  (e i64)
  (f i64))

(define (large-score [value : Large]) : i64
  (+ value.a value.b value.c value.d value.e value.f))

(define (tuple-score [value : (Tuple i64 i64 i64 i64 i64 i64)]) : i64
  (+
    (tuple-ref value 0)
    (tuple-ref value 1)
    (tuple-ref value 2)
    (tuple-ref value 3)
    (tuple-ref value 4)
    (tuple-ref value 5)))

(define (array-score [value : (Array i64 6)]) : i64
  (+
    (array-ref value 0)
    (array-ref value 1)
    (array-ref value 2)
    (array-ref value 3)
    (array-ref value 4)
    (array-ref value 5)))

(define (main) : i64
  (let
    [large : Large (Large 1 2 3 4 5 6)]
    [old-large : Large (replace! large (Large 7 8 9 10 11 12))]
    [tuple-value : (Tuple i64 i64 i64 i64 i64 i64) (tuple 13 14 15 16 17 18)]
    [old-tuple : (Tuple i64 i64 i64 i64 i64 i64)
      (replace! tuple-value (tuple 19 20 21 22 23 24))]
    [array-value : (Array i64 6) (array 25 26 27 28 29 30)]
    [old-array : (Array i64 6) (replace! array-value (array 31 32 33 34 35 36))]
    (begin
      (set! large.a 100)
      (set! (tuple-ref tuple-value 0) 100)
      (set! (array-ref array-value 0) 100)
      (test.assert-i64-eq (large-score old-large) 21 "large struct snapshot")
      (test.assert-i64-eq (tuple-score old-tuple) 93 "large tuple snapshot")
      (test.assert-i64-eq (array-score old-array) 165 "large array snapshot")
      (test.assert-i64-eq (large-score large) 150 "large struct replacement")
      (test.assert-i64-eq
        (tuple-score tuple-value)
        210
        "large tuple replacement")
      (test.assert-i64-eq
        (array-score array-value)
        270
        "large array replacement")
      42)))