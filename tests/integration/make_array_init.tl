(defstruct Point
  (x i64)
  (flag bool))

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

(define (main) : i64
  (let
    [ints : (Array i64) (make-array i64 3)]
    [flags : (Array bool) (make-array bool 2)]
    [chars : (Array char) (make-array char 1)]
    [texts : (Array String) (make-array String 2)]
    [points : (Array Point) (make-array Point 2)]
    [maybes : (Array Maybe) (make-array Maybe 2)]
    [empty-points : (Array Point) (make-array Point 0)]
    [int-score : i64 (+ (array-length ints) (array-ref ints 2))]
    [flag-score : i64 (score-bool (not (array-ref flags 0)))]
    [char-score : i64 (score-bool (= (array-ref chars 0) (init : char)))]
    [text-score : i64 (string-length (array-ref texts 1))]
    [point-score-value : i64 (point-score (array-ref points 1))]
    [maybe-score-value : i64 (maybe-score (array-ref maybes 1))]
    [empty-score : i64 (array-length empty-points)]
    [score : i64
      (+
        int-score
        (+
          flag-score
          (+
            char-score
            (+
              text-score
              (+ point-score-value (+ maybe-score-value empty-score))))))]
    (if (= score 7)
      42
      1)))