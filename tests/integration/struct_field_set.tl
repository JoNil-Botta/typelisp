;; #1521: `(set! place.field value)` mutates the field in place,
;; including register-resident locals, private dynamic-buffer elements,
;; fixed-array elements, tuple projections, mutable references, and nested fields.
(import stdlib.array)

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
      (set! p.x 17)
      (set! p.y 25)
      (+ p.x p.y))))

;; Compatibility dynamic-array regression coverage kept until public unsized
;; private dynamic-buffer spelling retained after public `(Array T)` removal.
(define (compat-dynamic-array-element-field-set) : i64
  (let
    [items : (__tl_dyn-array Pair) (array.make-array Pair 0)]
    (begin
      (__tl_array-push! items (Pair 1 2))
      (__tl_array-push! items (Pair 3 4))
      (__tl-project-set-field (array-ref items 1) x 30)
      (__tl-project-set-field (array-ref items 0) y 12)
      (+
        (__tl-project-field (array-ref items 1) x)
        (__tl-project-field (array-ref items 0) y)))))

(define (fixed-array-element-field-set) : i64
  (let
    [items : (Array Pair 2) (array (Pair 1 2) (Pair 3 4))]
    (begin
      (__tl-project-set-field (array-ref items 1) y 15)
      (+
        (__tl-project-field (array-ref items 1) x)
        (__tl-project-field (array-ref items 1) y)))))

(define (nested-field-set) : i64
  (let
    [o : Outer (Outer (Pair 5 6) 30)]
    (begin
      (set! o.p.y 12)
      (+ o.p.y o.z))))

(define (mut-ref-field-set! [p : (&mut p Pair)]) : unit
  (set! p.x 8))

(define (mut-ref-field-set-score) : i64
  (let
    [items : (Array Pair 1) (array (Pair 1 2))]
    (begin
      (mut-ref-field-set! (&mut (array-ref items 0)))
      (__tl-project-field (array-ref items 0) x))))

(define (tuple-field-set) : i64
  (let
    [t : (Tuple Pair i64) (tuple (Pair 6 7) 0)]
    (begin
      (__tl-project-set-field (tuple-ref t 0) x 11)
      (+
        (__tl-project-field (tuple-ref t 0) x)
        (__tl-project-field (tuple-ref t 0) y)))))

(define (main) : i64
  (-
    (+
      (local-field-set)
      (+
        (compat-dynamic-array-element-field-set)
        (+
          (fixed-array-element-field-set)
          (+ (nested-field-set) (+ (mut-ref-field-set-score) (tuple-field-set))))))
    128))