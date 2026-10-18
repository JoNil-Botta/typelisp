;; #1521: `(set! place.field value)` mutates the field in place,
;; including register-resident locals, private dynamic-buffer elements,
;; fixed-array elements, tuple projections, mutable references, and nested fields.
(defstruct Pair
  (x i64)
  (y i64))

(defstruct Outer
  (p Pair)
  (z i64))

(define (local-field-set) : i64
  (let
    [p : Pair (Pair 10 20)]
    (set! p.x 17)
    (set! p.y 25)
    (+ p.x p.y)))

;; Compatibility dynamic-array regression coverage kept until public unsized
;; private dynamic-buffer spelling retained after public `(Array T)` removal.
(define (compat-dynamic-array-element-field-set) : i64
  (let
    [items : (__tl_dyn-array Pair) (__tl_make-array Pair 0)]
    (__tl_array-push! items (Pair 1 2))
    (__tl_array-push! items (Pair 3 4))
    (__tl-project-set-field (array-ref items 1) x 30)
    (__tl-project-set-field (array-ref items 0) y 12)
    (+
      (__tl-project-field (array-ref items 1) x)
      (__tl-project-field (array-ref items 0) y))))

(define (fixed-array-element-field-set) : i64
  (let
    [items : (Array Pair 2) (array (Pair 1 2) (Pair 3 4))]
    (__tl-project-set-field (array-ref items 1) y 15)
    (+
      (__tl-project-field (array-ref items 1) x)
      (__tl-project-field (array-ref items 1) y))))

(define (nested-field-set) : i64
  (let
    [o : Outer (Outer (Pair 5 6) 30)]
    (set! o.p.y 12)
    (+ o.p.y o.z)))

(define (mut-ref-field-set! [p : (&mut p Pair)]) : unit
  (set! p.x 8))

(define (mut-ref-field-set-score) : i64
  (let
    [items : (Array Pair 1) (array (Pair 1 2))]
    (mut-ref-field-set! (&mut (array-ref items 0)))
    (__tl-project-field (array-ref items 0) x)))

(define (tuple-field-set) : i64
  (let
    [t : (Tuple Pair i64) (tuple (Pair 6 7) 0)]
    (__tl-project-set-field (tuple-ref t 0) x 11)
    (+
      (__tl-project-field (tuple-ref t 0) x)
      (__tl-project-field (tuple-ref t 0) y))))

(defstruct Narrow
  (a u8)
  (b u16))

(defstruct Floats
  (a f32)
  (b f32))

(defstruct Doubles
  (a f64)
  (b f64))

(define (packed-width-sibling-writes) : bool
  (let
    [n : Narrow (Narrow 1 2)]
    [f : Floats (Floats 1.0 2.0)]
    [d : Doubles (Doubles 1.0 2.0)]
    (set!
      n.a
      (begin
        (set! n.b 65535)
        255))
    (set!
      f.a
      (begin
        (set! f.b 20.5)
        7.5))
    (set!
      d.a
      (begin
        (set! d.b 20.5)
        7.5))
    (and
      (= n.a 255)
      (= n.b 65535)
      (= f.a 7.5)
      (= f.b 20.5)
      (= d.a 7.5)
      (= d.b 20.5))))

(defstruct Owner
  (value (Box i64))
  (sibling i64))

(define (boxed-field-effects) : bool
  (and
    (let
      [p : Owner (Owner (box 1) 2)]
      (set!
        p.value
        (begin
          (set! p.sibling 20)
          (box 7)))
      (and (= (deref p.value) 7) (= p.sibling 20)))
    ;; A by-value receiver is its variable's storage (SPEC 5.10): the
    ;; assignment in the value writes that storage, and the store then lands
    ;; in it.
    (let
      [p : Owner (Owner (box 1) 2)]
      (set!
        p.value
        (begin
          (set! p (Owner (box 7) 8))
          (box 5)))
      (and (= (deref p.value) 5) (= p.sibling 8)))))

(define (main) : i64
  (when (not (boxed-field-effects)) (return 2))
  (when (not (packed-width-sibling-writes)) (return 1))
  (-
    (+
      (local-field-set)
      (+
        (compat-dynamic-array-element-field-set)
        (+
          (fixed-array-element-field-set)
          (+ (nested-field-set) (+ (mut-ref-field-set-score) (tuple-field-set))))))
    128))