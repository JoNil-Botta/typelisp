;; Compact/full canonical vector capability coverage.
(import stdlib.test)
(import stdlib.vector)

(defstruct VectorCorePoint
  (x i64)
  (y i64))

(defenum VectorCoreChoice
  (First i64)
  (Second i64))

(defstruct VectorCoreRawHolder
  (ptr (MutPtr i64)))

(import (vector.vector i64 core) as compact_i64)
(import (vector.vector i64) as full_i64)
(import (vector.vector VectorCorePoint core) as compact_point)
(import (vector.vector VectorCoreChoice core) as compact_choice)
(import (vector.vector VectorCoreRawHolder core) as compact_raw)

(define (vector-core-point-score [point : VectorCorePoint]) : i64
  (+ (* (struct-get point x) 10) (struct-get point y)))

(define (vector-core-choice-value [choice : VectorCoreChoice]) : i64
  (match choice
    [(First value) value]
    [(Second value) value]))

(test
  vector-core-scalar-growth-order-and-full-coexistence
  (let
    [compact : compact_i64.Vec (compact_i64.with-capacity 1)]
    [full : full_i64.Vec (full_i64.new)]
    (begin
      (compact_i64.push! compact 10)
      (compact_i64.push! compact 32)
      (compact_i64.set! compact 0 11)
      (test.assert-i64-eq (compact_i64.len (& compact)) 2 "core len")
      (test.assert-i64-eq
        (compact_i64.capacity (& compact))
        2
        "core growth doubles capacity")
      (test.assert-i64-eq
        (compact_i64.get (& compact) 0 0)
        11
        "core set updates element")
      (test.assert-i64-eq
        (compact_i64.get (& compact) 1 0)
        32
        "core growth preserves order")
      (test.assert-i64-eq
        (compact_i64.get (& compact) -1 7)
        7
        "core get checks negative bounds")
      (full_i64.push! full 42)
      (match (full_i64.pop! full)
        [(full_i64.Pop.Empty)
          (test.assert-true false "full vector pop remains available")]
        [(full_i64.Pop.Ok value)
          (test.assert-i64-eq value 42 "full vector mode coexists with core")]))))

(test
  vector-core-struct-and-enum-elements
  (let
    [points : compact_point.Vec (compact_point.with-capacity 1)]
    [choices : compact_choice.Vec (compact_choice.new)]
    (begin
      (compact_point.push! points (VectorCorePoint 1 2))
      (compact_point.push! points (VectorCorePoint 3 4))
      (compact_point.set! points 0 (VectorCorePoint 9 8))
      (compact_choice.push! choices (First 7))
      (compact_choice.push! choices (Second 35))
      (test.assert-i64-eq
        (vector-core-point-score
          (compact_point.get (& points) 0 (VectorCorePoint 0 0)))
        98
        "core stores and mutates struct elements")
      (test.assert-i64-eq
        (vector-core-point-score
          (compact_point.get (& points) 1 (VectorCorePoint 0 0)))
        34
        "core preserves struct order while growing")
      (test.assert-i64-eq
        (vector-core-choice-value (compact_choice.get (& choices) 1 (First 0)))
        35
        "core stores enum elements"))))

(test
  vector-core-noncloneable-raw-pointer-aggregate
  (let
    [first : i64 10]
    [second : i64 32]
    [holders : compact_raw.Vec (compact_raw.with-capacity 1)]
    (begin
      (compact_raw.push!
        holders
        (VectorCoreRawHolder
          (unsafe
            (ptr-addr-of first))))
      (compact_raw.push!
        holders
        (VectorCoreRawHolder
          (unsafe
            (ptr-addr-of second))))
      (compact_raw.set!
        holders
        0
        (VectorCoreRawHolder
          (unsafe
            (ptr-addr-of second))))
      (test.assert-i64-eq
        (unsafe
          (ptr-read
            (struct-get
              (compact_raw.get
                (& holders)
                0
                (VectorCoreRawHolder (ptr-null : (MutPtr i64))))
              ptr)))
        32
        "core does not require clone support for raw-pointer aggregates")
      (test.assert-i64-eq
        (compact_raw.len (& holders))
        2
        "core raw-pointer aggregate growth succeeds"))))