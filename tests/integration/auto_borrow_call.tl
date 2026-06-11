(defstruct Pair
  (left i64)
  (right i64))

(defstruct Numbers
  (first i64)
  (second i64))

(defstruct RefBox
  (:lifetimes owner)
  (value (& owner Pair)))

(define (sum-pair [p : (& p Pair)]) : i64
  (+ (struct-get p left) (struct-get p right)))

(define (accept-tuple [t : (& t (Tuple i64 i64))]) : i64
  5)

(define (array-second [a : (& a (Array i64))]) : i64
  (array-ref a 1))

(define (text-len [text : (& text str)]) : i64
  (string-length text))

(define (ref-score [n : (& n i64)]) : i64
  2)

(define (call-pair-f [f : (-> (& p Pair) i64)] [p : Pair]) : i64
  (f p))

(define (box-pair [p : Pair]) : (RefBox p)
  (RefBox p))

(define (box-sum [box : (RefBox owner)]) : i64
  (sum-pair (struct-get box value)))

(define (scoped-use-after-auto-borrow [text : String]) : i64
  (begin
    (let
      [n : i64 (text-len text)]
      unit)
    (string-length text)))

(define (main) : i64
  (let
    [p : Pair (Pair 11 13)]
    [t : (Tuple i64 i64) (tuple 5 37)]
    [items : (Array i64) (make-array i64 3)]
    [text : String "borrow"]
    [nums : Numbers (Numbers 3 4)]
    [f : (-> (& p Pair) i64) (lambda ([arg : (& p Pair)]) : i64 (sum-pair arg))]
    (begin
      (array-set! items 0 17)
      (array-set! items 1 19)
      (array-set! items 2 23)
      (let
        [direct : i64 (sum-pair p)]
        [explicit : i64 (sum-pair (& p))]
        [via-f : i64 (f p)]
        [via-lambda : i64
          ((lambda ([arg : (& arg Pair)]) : i64 (sum-pair arg)) p)]
        [via-wrapper : i64 (call-pair-f f p)]
        [via-box : i64 (box-sum (box-pair p))]
        [tuple-value : i64 (accept-tuple t)]
        [array-value : i64 (array-second items)]
        [text-value : i64 (text-len text)]
        [projection-value : i64
          (+
            (ref-score (struct-get nums first))
            (+ (ref-score (tuple-ref t 1)) (ref-score (array-ref items 2))))]
        [scoped-value : i64 (scoped-use-after-auto-borrow "scope")]
        (if (and
          (= direct 24)
          (= explicit 24)
          (= via-f 24)
          (= via-lambda 24)
          (= via-wrapper 24)
          (= via-box 24)
          (= tuple-value 5)
          (= array-value 19)
          (= text-value 6)
          (= projection-value 6)
          (= scoped-value 5))
          42
          1)))))