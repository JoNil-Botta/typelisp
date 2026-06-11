;; #1521: `(set! (struct-get place field) value)` mutates the field in place,
;; including register-resident locals, dynamic/fixed array elements, tuple
;; projections, mutable references, and nested fields.
(defstruct Pair
  (x i64)
  (y i64))

(defstruct Outer
  (p Pair)
  (z i64))

(define (local-field-set) : i64
  (let
    [p : Pair (Pair 10 20)]
    (begin
      (set! (struct-get p x) 17)
      (set! (struct-get p y) 25)
      (+ (struct-get p x) (struct-get p y)))))

(define (array-element-field-set) : i64
  (let
    [items : (Array Pair) (make-array Pair 0)]
    (begin
      (array-push! items (Pair 1 2))
      (array-push! items (Pair 3 4))
      (set! (struct-get (array-ref items 1) x) 30)
      (set! (struct-get (array-ref items 0) y) 12)
      (+ (struct-get (array-ref items 1) x) (struct-get (array-ref items 0) y)))))

(define (fixed-array-element-field-set) : i64
  (let
    [items : (Array Pair 2) (array (Pair 1 2) (Pair 3 4))]
    (begin
      (set! (struct-get (array-ref items 1) y) 15)
      (+ (struct-get (array-ref items 1) x) (struct-get (array-ref items 1) y)))))

(define (nested-field-set) : i64
  (let
    [o : Outer (Outer (Pair 5 6) 30)]
    (begin
      (set! (struct-get (struct-get o p) y) 12)
      (+ (struct-get (struct-get o p) y) (struct-get o z)))))

(define (mut-ref-field-set! [p : (&mut p Pair)]) : unit
  (set! (struct-get p x) 8))

(define (mut-ref-field-set-score) : i64
  (let
    [items : (Array Pair) (make-array Pair 0)]
    (begin
      (array-push! items (Pair 1 2))
      (mut-ref-field-set! (&mut (array-ref items 0)))
      (struct-get (array-ref items 0) x))))

(define (tuple-field-set) : i64
  (let
    [t : (Tuple Pair i64) (tuple (Pair 6 7) 0)]
    (begin
      (set! (struct-get (tuple-ref t 0) x) 11)
      (+ (struct-get (tuple-ref t 0) x) (struct-get (tuple-ref t 0) y)))))

(define (main) : i64
  (-
    (+
      (local-field-set)
      (+
        (array-element-field-set)
        (+
          (fixed-array-element-field-set)
          (+ (nested-field-set) (+ (mut-ref-field-set-score) (tuple-field-set))))))
    128))