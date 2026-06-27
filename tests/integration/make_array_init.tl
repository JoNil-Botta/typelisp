(import stdlib.array)
(import "stdlib/string.tl")

(defstruct Point
  (x i64)
  (flag bool))

(defstruct Bag
  (items (Array i64)))

(defenum Maybe
  (None)
  (Some i64))

(define (score-bool [ok : bool]) : i64
  (if ok
    1
    0))

(define (maybe-score [value : Maybe]) : i64
  (match value
    [(None) 1]
    [(Some _) 0]))

(define (point-score [value : Point]) : i64
  (+ (struct-get value x) (score-bool (not (struct-get value flag)))))

(define (bag-score [bags : (Array Bag)]) : i64
  (begin
    (array.array-push! (struct-get (array.array-ref bags 0) items) 7)
    (score-bool
      (and
        (= (array.array-length (struct-get (array.array-ref bags 0) items)) 1)
        (= (array.array-ref (struct-get (array.array-ref bags 0) items) 0) 7)
        (= (array.array-length (struct-get (array.array-ref bags 1) items)) 0)))))

(define (main) : i64
  (let
    [ints : (Array i64) (array.make-array i64 3)]
    [flags : (Array bool) (array.make-array bool 2)]
    [chars : (Array char) (array.make-array char 1)]
    [texts : (Array String) (array.make-array String 2)]
    [points : (Array Point) (array.make-array Point 2)]
    [maybes : (Array Maybe) (array.make-array Maybe 2)]
    [bags : (Array Bag) (array.make-array Bag 2)]
    [empty-points : (Array Point) (array.make-array Point 0)]
    [int-score : i64 (+ (array.array-length ints) (array.array-ref ints 2))]
    [flag-score : i64 (score-bool (not (array.array-ref flags 0)))]
    [char-score : i64 (score-bool (= (array.array-ref chars 0) (init : char)))]
    [text-score : i64 (string-length (array.array-ref texts 1))]
    [point-score-value : i64 (point-score (array.array-ref points 1))]
    [maybe-score-value : i64 (maybe-score (array.array-ref maybes 1))]
    [bag-score-value : i64 (bag-score bags)]
    [empty-score : i64 (array.array-length empty-points)]
    [score : i64
      (+
        int-score
        (+
          flag-score
          (+
            char-score
            (+
              text-score
              (+
                point-score-value
                (+ maybe-score-value (+ bag-score-value empty-score)))))))]
    (if (= score 8)
      42
      1)))