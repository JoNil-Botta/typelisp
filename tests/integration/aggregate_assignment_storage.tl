;; Capture all constructor operands before touching an existing destination,
;; and keep a captured receiver on its old value across whole rebinding.
(defstruct Inner
  (a i64)
  (b i64)
  (c i64))

(defstruct Outer
  (left Inner)
  (right Inner))

(defstruct Small
  (a i32)
  (b i32))

(defenum Choice
  (Pair Inner Inner))

(defstruct Owner
  (handle (Box i64))
  (padding i64)
  (more i64))

(defstruct Owners
  (left Owner)
  (right Owner))

(define global-inner : Inner
  (Inner 1 2 3))
(define global-copy : Inner
  global-inner)
(define global-owner : Owner
  (Owner (box 1) 2 3))

(define (constructor-swap?) : bool
  (let
    [items : (Array Outer 1) (array (Outer (Inner 1 2 3) (Inner 4 5 6)))]
    (begin
      (set!
        (array-ref items 0)
        (Outer (array-ref items 0).right (array-ref items 0).left))
      (and (= (array-ref items 0).left.a 4) (= (array-ref items 0).right.a 1)))))

(define (enum-swap?) : bool
  (let
    [items : (Array Choice 1) (array (Choice.Pair (Inner 1 2 3) (Inner 4 5 6)))]
    (begin
      (match (array-ref items 0)
        [(Choice.Pair left right)
          (set! (array-ref items 0) (Choice.Pair right left))])
      (match (array-ref items 0)
        [(Choice.Pair left right) (and (= left.a 4) (= right.a 1))]))))

(define (receiver-reassignment?) : bool
  (let
    [p : Inner (Inner 1 2 3)]
    [q : Inner (Inner 7 8 9)]
    (begin
      (set!
        p.a
        (begin
          (set! p q)
          5))
      (and (= p.a 7) (= p.b 8) (= p.c 9) (= q.a 7)))))

(define (small-reassignment?) : bool
  (let
    [p : Small (Small 1 2)]
    [q : Small (Small 7 8)]
    (begin
      (set!
        p.a
        (begin
          (set! p q)
          5))
      (and (= p.a 7) (= p.b 8) (= q.a 7)))))

(define (tuple-reassignment?) : bool
  (let
    [p : (Tuple i64 i64 i64) (tuple 1 2 3)]
    [q : (Tuple i64 i64 i64) (tuple 7 8 9)]
    (begin
      (set!
        (tuple-ref p 0)
        (begin
          (set! p q)
          5))
      (and
        (= (tuple-ref p 0) 7)
        (= (tuple-ref p 1) 8)
        (= (tuple-ref p 2) 9)
        (= (tuple-ref q 0) 7)))))

(define (owning-swap?) : bool
  (let
    [p : Owners (Owners (Owner (box 1) 2 3) (Owner (box 4) 5 6))]
    [left-address : u64
      (unsafe
        (ptr-read (ptr-cast (ptr-addr-of p.left.handle) : (Ptr u64))))]
    [right-address : u64
      (unsafe
        (ptr-read (ptr-cast (ptr-addr-of p.right.handle) : (Ptr u64))))]
    (begin
      (set! p (Owners p.right p.left))
      (and
        (= (deref p.left.handle) 4)
        (= (deref p.right.handle) 1)
        (=
          left-address
          (unsafe
            (ptr-read (ptr-cast (ptr-addr-of p.right.handle) : (Ptr u64)))))
        (=
          right-address
          (unsafe
            (ptr-read (ptr-cast (ptr-addr-of p.left.handle) : (Ptr u64)))))))))

(define (global-storage?) : bool
  (let
    [source : Inner (Inner 7 8 9)]
    [before : Inner global-inner]
    [captured : (MutPtr i64)
      (unsafe
        (ptr-addr-of global-inner.a))]
    (begin
      (set!
        global-inner.a
        (begin
          (set! global-inner source)
          5))
      (set! source.b 99)
      (and
        (= global-inner.a 7)
        (= global-inner.b 8)
        (= global-inner.c 9)
        (=
          (unsafe
            (ptr-read captured))
          5)
        (= source.a 7)
        (= before.a 1)
        (= before.b 2)
        (= global-copy.a 1)
        (= global-copy.b 2)))))

(define (global-owning-transfer?) : bool
  (let
    [replacement : Owner (Owner (box 42) 8 9)]
    [captured : (MutPtr i64)
      (unsafe
        (ptr-addr-of global-owner.padding))]
    [address : u64
      (unsafe
        (ptr-read (ptr-cast (ptr-addr-of replacement.handle) : (Ptr u64))))]
    (begin
      (set!
        global-owner.padding
        (begin
          (set! global-owner replacement)
          5))
      (and
        (= (deref global-owner.handle) 42)
        (= global-owner.padding 8)
        (= global-owner.more 9)
        (=
          (unsafe
            (ptr-read captured))
          5)
        (=
          address
          (unsafe
            (ptr-read (ptr-cast (ptr-addr-of global-owner.handle) : (Ptr u64)))))))))

(define (main) : i64
  (cond
    [(not (constructor-swap?)) 1]
    [(not (enum-swap?)) 2]
    [(not (receiver-reassignment?)) 3]
    [(not (small-reassignment?)) 4]
    [(not (tuple-reassignment?)) 5]
    [(not (owning-swap?)) 6]
    [(not (global-storage?)) 7]
    [(not (global-owning-transfer?)) 8]
    [else 42]))