;; #5425: tuples have pointer-slot representation inside inline aggregates.
;; Packing a tuple's elements inline made a following fixed array overlap the
;; tuple pointer, so projecting the tuple crashed on Windows.
(import stdlib.io)

(defenum Marker
  (Empty)
  (Number i64))

(defstruct TupleArray
  (pair (Tuple u8 bool))
  (items (Array i16 3)))

(defstruct EnumTupleArray
  (marker Marker)
  (pair (Tuple u16 i8))
  (items (Array u8 2)))

(defstruct Inner
  (pair (Tuple u16 u16))
  (items (Array u8 3)))

(defstruct Outer
  (prefix u8)
  (inner Inner)
  (suffix u16))

(define (marker-value [marker : Marker]) : i64
  (match marker
    [(Empty) 0]
    [(Number value) value]))

(define (main) : i64
  (let
    [value : TupleArray (TupleArray (tuple 7 true) (array 1 2 3))]
    [borrowed (& value)]
    [pair-value (struct-get borrowed pair)]
    [array-value (struct-get borrowed items)]
    [mixed : EnumTupleArray
      (EnumTupleArray (Number 5) (tuple 11 4) (array 6 9))]
    [nested : Outer (Outer 2 (Inner (tuple 8 12) (array 3 4 7)) 13)]
    (begin
      (io.print (cast (tuple-ref pair-value 0) : i64))
      (io.print (cast (array-ref array-value 2) : i64))
      (if (and
        (= (marker-value (struct-get mixed marker)) 5)
        (= (cast (tuple-ref (struct-get mixed pair) 0) : i64) 11)
        (= (cast (array-ref (struct-get mixed items) 1) : i64) 9)
        (= (cast (struct-get nested prefix) : i64) 2)
        (=
          (cast (tuple-ref (struct-get (struct-get nested inner) pair) 1) : i64)
          12)
        (=
          (cast
            (array-ref (struct-get (struct-get nested inner) items) 2)
            : i64)
          7)
        (= (cast (struct-get nested suffix) : i64) 13))
        0
        1))))