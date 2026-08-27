;; lint-allow: unused-import
(import stdlib.string)

(defstruct Point
  (x i64)
  (flag bool))

(defstruct Bag
  (items (__tl_dyn-array i64)))

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
  (+ value.x (score-bool (not value.flag))))

(define (bag-score [bags : (__tl_dyn-array Bag)]) : i64
  (let
    [first : (&mut bags Bag) (&mut (array-ref bags 0))]
    [first-ok : bool
      (begin
        (__tl_array-push! first.items 7)
        (and (= (array-length first.items) 1) (= (array-ref first.items 0) 7)))]
    [second : (& bags Bag) (& (array-ref bags 1))]
    (score-bool (and first-ok (= (array-length second.items) 0)))))

(define (main) : i64
  (let
    [ints : (__tl_dyn-array i64) (__tl_make-array i64 3)]
    [flags : (__tl_dyn-array bool) (__tl_make-array bool 2)]
    ;; lint-allow: single-element-array-cell
    [chars : (__tl_dyn-array char) (__tl_make-array char 1)]
    [texts : (__tl_dyn-array String) (__tl_make-array String 2)]
    [points : (__tl_dyn-array Point) (__tl_make-array Point 2)]
    [maybes : (__tl_dyn-array Maybe) (__tl_make-array Maybe 2)]
    [bags : (__tl_dyn-array Bag) (__tl_make-array Bag 2)]
    [empty-points : (__tl_dyn-array Point) (__tl_make-array Point 0)]
    [int-score : i64 (+ (array-length ints) (array-ref ints 2))]
    [flag-score : i64 (score-bool (not (array-ref flags 0)))]
    [char-score : i64 (score-bool (= (array-ref chars 0) (init : char)))]
    [text-score : i64 (string.string-length (array-ref texts 1))]
    [point-score-value : i64 (point-score (array-ref points 1))]
    [maybe-score-value : i64 (maybe-score (array-ref maybes 1))]
    [bag-score-value : i64 (bag-score bags)]
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
              (+
                point-score-value
                (+ maybe-score-value (+ bag-score-value empty-score)))))))]
    (if (= score 8)
      42
      1)))