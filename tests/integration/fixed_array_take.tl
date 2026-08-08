;; Public fixed-array take returns the old value and immediately restores the
;; slot with that element type's `init` value. Exercise both direct owned-place
;; scalar storage and an aggregate reached through a mutable reference.
(import stdlib.string)

(defstruct Triple
  (a i64)
  (b i64)
  (c i64))

(define evaluation-trace : i64
  0)

(define (mark-index [digit : i64]) : i64
  (begin
    (set! evaluation-trace (+ (* evaluation-trace 10) digit))
    0))

(define (triple-score [value : Triple]) : i64
  (+ (struct-get value a) (+ (struct-get value b) (struct-get value c))))

(define (take-triple [items : (&mut items (Array Triple 2))] [index : i64]) : Triple
  (array-take! items index))

(define (main) : i64
  (let
    [numbers : (Array i64 3) (array 4 7 9)]
    [triples : (Array Triple 2) (array (Triple 1 2 3) (Triple 8 9 10))]
    [texts : (Array String 2) (array "hello" "later")]
    [nested : (Array (Array i64 1) 1) (array (array 33))]
    [old-number : i64 (array-take! numbers 1)]
    [old-triple : Triple (take-triple (&mut triples) 0)]
    [old-text : String (array-take! texts 0)]
    [old-nested : i64
      (array-take! (array-ref nested (mark-index 1)) (mark-index 2))]
    (if (and
      (= old-number 7)
      (= (array-ref numbers 1) 0)
      (= (triple-score old-triple) 6)
      (= (triple-score (array-ref triples 0)) 0)
      (= (triple-score (array-ref triples 1)) 27)
      (= (string.string-length old-text) 5)
      (= (string.string-length (& (array-ref texts 0))) 0)
      (= (string.string-length (& (array-ref texts 1))) 5)
      (= old-nested 33)
      (= (array-ref (array-ref nested 0) 0) 0)
      (= evaluation-trace 12))
      42
      1)))