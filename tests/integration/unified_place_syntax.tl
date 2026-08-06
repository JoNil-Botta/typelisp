(defstruct Pair
  (left i64)
  (right i64))

(define (read-ref [value : (& source i64)]) : i64
  (deref value))

(define (write-ref! [value : (&mut target i64)] [next : i64]) : unit
  (set! (deref value) next))

(define (write-tuple-ref! [value : (&mut target (Tuple i64 i64))] [next : i64]) : unit
  (set! (tuple-ref value 1) next))

(define (main) : i64
  (let
    [scalar : i64 1]
    [pair : Pair (Pair 2 3)]
    [tuple-value : (Tuple i64 i64) (tuple 4 5)]
    [items : (Array i64 2) (array 6 7)]
    [cell : (Box i64) (box 8)]
    [outer : (Box (Box i64)) (box (box 9))]
    [owned-tuple : (Tuple (Box i64) i64) (tuple (box 15) 16)]
    (begin
      (write-ref! (&mut scalar) 10)
      (set! pair.left 11)
      (write-tuple-ref! (&mut tuple-value) 12)
      (set! (array-ref items 0) 13)
      (set! (deref cell) 14)
      (let
        [inner : (Box i64) (deref outer)]
        [borrowed : (& cell i64) (& (deref cell))]
        [moved-element : (Box i64) (tuple-ref owned-tuple 0)]
        (begin
          (set! (tuple-ref owned-tuple 0) (box 17))
          (if (and
            (= (read-ref (& scalar)) 10)
            (= pair.left 11)
            (= (tuple-ref tuple-value 1) 12)
            (= (array-ref items 0) 13)
            (= (deref borrowed) 14)
            (= (deref inner) 9)
            (= (deref moved-element) 15)
            (= (deref (tuple-ref owned-tuple 0)) 17))
            42
            1))))))