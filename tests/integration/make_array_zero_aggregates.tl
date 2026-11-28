;; Fixed storage starts with zero bytes for every element, including aggregates.
(defstruct Point
  (x i64)
  (flag bool))

(defstruct Pair
  (left i64)
  (right i64))

(defenum Maybe
  (Some i64)
  (None))

(define (tuple-score) : i64
  (let
    [items : (Array (Tuple i64 String) 2) (make-array (Tuple i64 String) 2)]
    (begin
      (set! (tuple-ref (array-ref items 0) 0) 40)
      (set! (tuple-ref (array-ref items 1) 0) 2)
      (+
        (tuple-ref (array-ref items 0) 0)
        (+
          (tuple-ref (array-ref items 1) 0)
          (__tl_string_length (tuple-ref (array-ref items 0) 1)))))))

(define (box-score) : i64
  (let
    [boxes : (Array (Box Point) 3)
      (array (box (Point 0 false)) (box (Point 0 false)) (box (Point 0 false)))]
    (begin
      (set! (deref (array-ref boxes 0)).x 40)
      (set! (deref (array-ref boxes 1)).x 2)
      (if (and
        (= (deref (array-ref boxes 0)).x 40)
        (= (deref (array-ref boxes 1)).x 2)
        (= (deref (array-ref boxes 2)).x 0))
        (+ (deref (array-ref boxes 0)).x (deref (array-ref boxes 1)).x)
        0))))

(define (enum-score) : i64
  (let
    [items : (Array Maybe 2) (make-array Maybe 2)]
    (match (array-ref items 1)
      [(None) 0]
      [(Some value) (- 42 value)])))

(define (struct-score) : i64
  (let
    [pairs : (Array Pair 2) (make-array Pair 2)]
    (begin
      (set! (array-ref pairs 0).left 40)
      (set! (array-ref pairs 0).right 2)
      (if (and (= (array-ref pairs 0).left 40) (= (array-ref pairs 1).left 0))
        (+ (array-ref pairs 0).left (array-ref pairs 0).right)
        0))))

(define (main) : i64
  (if (and
    (= (tuple-score) 42)
    (= (box-score) 42)
    (= (enum-score) 42)
    (= (struct-score) 42))
    42
    1))