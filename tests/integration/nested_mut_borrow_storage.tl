;; Inline projections must lend the existing bytes, including register-sized
;; intermediates reached through references, array/tuple slots and boxes.
(defstruct Leaf
  (x i32)
  (y i32))

(defstruct Middle
  (pad i64)
  (leaf Leaf))

(defstruct Outer
  (head i64)
  (middle Middle)
  (tail i64))

(defstruct PointerLeaf
  (p (Ptr i64)))

(defstruct PointerOuter
  (head i64)
  (leaf PointerLeaf)
  (tail i64))

(defstruct FloatLeaf
  (x f32)
  (y f32))

(defstruct FloatOuter
  (head i64)
  (leaf FloatLeaf)
  (tail i64))

(defstruct RefOuter
  (:lifetimes leaf)
  (leaf (&mut leaf Leaf)))

;; Keep memory-class global projections alongside the register-global cases.
(define state : Outer
  (Outer 10 (Middle 20 (Leaf 1 2)) 30))
(define index-calls : i64
  0)

(define (index-once) : i64
  (+= index-calls 1)
  1)

(define (write-pair! [x : (&mut x i32)] [y : (&mut y i32)]) : unit
  (set! (deref x) (cast 5 : i32))
  (set! (deref y) (cast 9 : i32)))

(define (write! [x : (&mut x i32)] [value : i32]) : unit
  (set! (deref x) value))

(define (read [x : (& x i32)]) : i32
  (deref x))

(define (nested! [p : (&mut p Outer)]) : unit
  (write-pair! (&mut p.middle.leaf.x) (&mut p.middle.leaf.y)))

(define (memory-and-reference) : bool
  (let
    [s : Outer (Outer 10 (Middle 20 (Leaf 1 2)) 30)]
    (write-pair! (&mut s.middle.leaf.x) (&mut s.middle.leaf.y))
    (let
      [first : bool
        (and
          (= s.middle.leaf.x (cast 5 : i32))
          (= s.middle.leaf.y (cast 9 : i32)))]
      (set! s.middle.leaf (Leaf 3 4))
      (nested! (&mut s))
      (and
        first
        (= (read (& s.middle.leaf.x)) (cast 5 : i32))
        (= (read (& s.middle.leaf.y)) (cast 9 : i32))
        (= s.head 10)
        (= s.middle.pad 20)
        (= s.tail 30)))))

(define (array-slots) : bool
  (let
    [xs : (Array Leaf 2) (array (Leaf 1 2) (Leaf 3 4))]
    (set! index-calls 0)
    (write! (&mut (array-ref xs (index-once)).x) (cast 5 : i32))
    (write! (&mut (array-ref xs 1).y) (cast 9 : i32))
    (and
      (= (array-ref xs 1).x (cast 5 : i32))
      (= (array-ref xs 1).y (cast 9 : i32))
      (= (array-ref xs 0).x (cast 1 : i32))
      (= index-calls 1))))

(define (dynamic-array-slots) : bool
  (let
    [xs : (__tl_dyn-array Leaf) (__tl_make-array Leaf 2)]
    (set! (array-ref xs 1) (Leaf 1 2))
    (write! (&mut (array-ref xs 1).x) (cast 5 : i32))
    (and
      (= (array-ref xs 1).x (cast 5 : i32))
      (= (array-ref xs 1).y (cast 2 : i32)))))

(define (tuple-slots) : bool
  (let
    [t : (Tuple i64 Leaf) (tuple 10 (Leaf 1 2))]
    (write-pair! (&mut (tuple-ref t 1).x) (&mut (tuple-ref t 1).y))
    (and
      (= (tuple-ref t 1).x (cast 5 : i32))
      (= (tuple-ref t 1).y (cast 9 : i32))
      (= (tuple-ref t 0) 10))))

(define (boxed-slots) : bool
  (let
    [b : (Box Leaf) (box (Leaf 1 2))]
    (write! (&mut (deref b).x) (cast 5 : i32))
    (write! (&mut (deref b).y) (cast 9 : i32))
    (and (= (deref b).x (cast 5 : i32)) (= (deref b).y (cast 9 : i32)))))

(define (write-pointer! [p : (&mut p (Ptr i64))]) : unit
  (set!
    (deref p)
    (unsafe
      (int->ptr (cast 5 : u64) : (Ptr i64)))))

(define (nested-pointer! [p : (&mut p PointerOuter)]) : unit
  (write-pointer! (&mut p.leaf.p)))

(define (write-original! [p : (&mut p (Ptr i64))] [expected : u64]) : bool
  (let
    [same : bool
      (=
        (unsafe
          (ptr-read (ptr-cast (ptr-addr-of p) : (Ptr u64))))
        expected)]
    (write-pointer! p)
    same))

(define (pointer-fields) : bool
  (let
    [s : PointerOuter (PointerOuter 10 (PointerLeaf (ptr-null : (Ptr i64))) 30)]
    [original : u64
      (unsafe
        (ptr->int (ptr-addr-of s.leaf.p)))]
    [same : bool (write-original! (&mut s.leaf.p) original)]
    (set! s.leaf.p (ptr-null : (Ptr i64)))
    (nested-pointer! (&mut s))
    (and
      same
      (=
        (unsafe
          (ptr->int s.leaf.p))
        (cast 5 : u64))
      (= s.head 10)
      (= s.tail 30))))

(define (write-float! [x : (&mut x f32)]) : unit
  (set! (deref x) (cast 5.0 : f32)))

(define (nested-float! [p : (&mut p FloatOuter)]) : unit
  (write-float! (&mut p.leaf.x)))

(define (float-fields) : bool
  (let
    [s : FloatOuter
      (FloatOuter 10 (FloatLeaf (cast 1.0 : f32) (cast 2.0 : f32)) 30)]
    (nested-float! (&mut s))
    (and
      (= s.leaf.x (cast 5.0 : f32))
      (= s.leaf.y (cast 2.0 : f32))
      (= s.tail 30))))

(define (reference-field! [p : (&mut p (RefOuter leaf))]) : unit
  (write! (&mut p.leaf.x) (cast 5 : i32)))

(define (reference-holder! [p : (&mut p Leaf)]) : unit
  (let
    [holder (RefOuter p)]
    (reference-field! (&mut holder))))

(define (reference-field) : bool
  (let
    [s : Leaf (Leaf 1 2)]
    (reference-holder! (&mut s))
    (= s.x (cast 5 : i32))))

(define (non-call-borrow) : bool
  (let
    [s : Outer (Outer 10 (Middle 20 (Leaf 1 2)) 30)]
    (set! (deref (&mut s.middle.leaf.x)) (cast 5 : i32))
    (and (= s.middle.leaf.x (cast 5 : i32)) (= s.middle.leaf.y (cast 2 : i32)))))

(define (memory-global) : bool
  (write! (&mut state.middle.leaf.x) (cast 5 : i32))
  (and (= state.middle.leaf.x (cast 5 : i32)) (= state.tail 30)))

(define (main) : i64
  (cond
    [(not (memory-and-reference)) 1]
    [(not (array-slots)) 2]
    [(not (tuple-slots)) 3]
    [(not (boxed-slots)) 4]
    [(not (pointer-fields)) 5]
    [(not (float-fields)) 6]
    [(not (dynamic-array-slots)) 7]
    [(not (reference-field)) 8]
    [(not (non-call-borrow)) 9]
    [(not (memory-global)) 10]
    [else 42]))
