;; Register-class globals have static homes, including packed and SSE words.
;; Borrows must lend those bytes, preserving disjoint fields and slot identity.
(defstruct Word
  (x i64))

(defstruct Pair
  (x i64)
  (y i64))

(defstruct Narrow
  (x i8)
  (guard i8)
  (y i16)
  (z i32))

(defstruct FloatPair
  (x f32)
  (y f32))

(defstruct Mixed
  (guard i64)
  (x f64))

(defstruct PointerPair
  (guard i64)
  (p (Ptr i64)))

(defstruct Outer
  (head i64)
  (pair Pair)
  (tail i64))

(define word : Word
  (Word 1))
(define pair : Pair
  (Pair 1 2))
(define narrow : Narrow
  (Narrow 1 2 3 4))
(define floats : FloatPair
  (FloatPair 1.0 2.0))
(define mixed : Mixed
  (Mixed 10 1.0))
(define pointers : PointerPair
  (PointerPair 10 (ptr-null : (Ptr i64))))
(define outer : Outer
  (Outer 10 (Pair 1 2) 30))

(define (write! [p : (&mut p i64)] [value : i64]) : unit
  (set! (deref p) value))

(define (write-two! [x : (&mut x i64)] [y : (&mut y i64)]) : unit
  (write! x 5)
  (write! y 9))

(define (read [p : (& p i64)]) : i64
  (deref p))

;; Exercise a unit function ending in the global field call as well.
(define (tail-write!) : unit
  (write! (&mut pair.y) 17))

(define (integer-fields) : bool
  (write! (&mut word.x) 5)
  (write-two! (&mut pair.x) (&mut pair.y))
  (let
    [first : bool (and (= word.x 5) (= pair.x 5) (= pair.y 9))]
    (tail-write!)
    (write! (&mut pair.x) 11)
    (write! (&mut word.x) 13)
    (and
      first
      (= (read (& word.x)) 13)
      (= (read (& pair.x)) 11)
      (= (read (& pair.y)) 17))))

(define (write-narrow! [x : (&mut x i8)] [y : (&mut y i16)] [z : (&mut z i32)]) : unit
  (set! (deref x) (cast -7 : i8))
  (set! (deref y) (cast -300 : i16))
  (set! (deref z) (cast -100000 : i32)))

(define (narrow-fields) : bool
  (write-narrow! (&mut narrow.x) (&mut narrow.y) (&mut narrow.z))
  (and
    (= narrow.x (cast -7 : i8))
    (= narrow.guard (cast 2 : i8))
    (= narrow.y (cast -300 : i16))
    (= narrow.z (cast -100000 : i32))))

(define (write-float! [p : (&mut p f32)]) : unit
  (set! (deref p) (cast 5.0 : f32)))

(define (write-double! [p : (&mut p f64)]) : unit
  (set! (deref p) 9.0))

(define (floating-fields) : bool
  (write-float! (&mut floats.y))
  (write-double! (&mut mixed.x))
  (and
    (= floats.x (cast 1.0 : f32))
    (= floats.y (cast 5.0 : f32))
    (= mixed.guard 10)
    (= mixed.x 9.0)))

(define (write-original! [p : (&mut p (Ptr i64))] [expected : u64]) : bool
  (let
    [same : bool
      (=
        (unsafe
          (ptr-read (ptr-cast (ptr-addr-of p) : (Ptr u64))))
        expected)]
    (set!
      (deref p)
      (unsafe
        (int->ptr (cast 5 : u64) : (Ptr i64))))
    same))

(define (read-original [p : (& p (Ptr i64))] [expected : u64]) : bool
  (and
    (=
      (unsafe
        (ptr-read (ptr-cast (ptr-addr-of p) : (Ptr u64))))
      expected)
    (=
      (unsafe
        (ptr->int (deref p)))
      (cast 5 : u64))))

(define (pointer-fields) : bool
  (let
    [original : u64
      (unsafe
        (ptr->int (ptr-addr-of pointers.p)))]
    [same : bool (write-original! (&mut pointers.p) original)]
    (and same (read-original (& pointers.p) original) (= pointers.guard 10))))

(define (nested-fields) : bool
  (write-two! (&mut outer.pair.x) (&mut outer.pair.y))
  (and
    (= (read (& outer.pair.x)) 5)
    (= (read (& outer.pair.y)) 9)
    (= outer.head 10)
    (= outer.tail 30)))

(define (main) : i64
  (cond
    [(not (integer-fields)) 1]
    [(not (narrow-fields)) 2]
    [(not (floating-fields)) 3]
    [(not (pointer-fields)) 4]
    [(not (nested-fields)) 5]
    [else 42]))
