;; A shared borrow of a local that has no address of its own (a scalar, a
;; register-resident struct, or a field of one) points at a copy in a frame slot
;; of the borrowing function, never at storage in the current arena (#9297).
;; The checker ties such a reference to the local, which outlives a `with-arena`
;; or `in-arena` form around the borrow, so the reference must survive that
;; form's rewind and an `arena.destroy-safe!` of its arena. Each case reuses
;; the released arena memory before it reads through the reference, and the
;; no-allocation case measures `profile.alloc-total` around the borrows. `main`
;; yields 42 only if every read sees its local's value and no borrow allocates.
(import stdlib.arena)
(import stdlib.profile)

;; Two words: register-resident.
(defstruct Pair
  (x i64)
  (y i64))

;; One word holding two narrow fields.
(defstruct Narrow
  (a i32)
  (b i32))

(defstruct Holder
  (:lifetimes h)
  (tag i64)
  (r (& h i64)))

(defenum Opt
  (Some i64)
  (None))

;; The sum of every element `clobber-arena` wrote, so its stores stay live.
(define clobbered : i64
  0)

;; Allocates and fills enough of the current arena to overwrite anything a
;; rewound or destroyed arena left at the same addresses.
(define (clobber-arena) : unit
  (let
    [junk : (__tl_dyn-array i64) (__tl_make-array i64 256)]
    [i : i64 0]
    (while (< i 256)
      (set! (array-ref junk i) 7)
      (set! i (+ i 1)))
    (set! i 0)
    (while (< i 256)
      (set! clobbered (+ clobbered (array-ref junk i)))
      (set! i (+ i 1)))))

(define (same-ref [r : (& r i64)]) : (& r i64)
  r)

(define (read-ref [r : (& i64)]) : i64
  (deref r))

;; Each local kind borrowed inside `with-arena`.
(define (case-kinds) : i64
  (let
    [n : i64 42]
    [f : f64 2.5]
    [flag : bool true]
    [c : char 'Z']
    [w : i32 -9]
    [p : Pair (Pair 11 12)]
    [q : Narrow (Narrow 21 22)]
    [rn : (& n i64) (with-arena tmp (& n))]
    [rf : (& f f64) (with-arena tmp (& f))]
    [rflag : (& flag bool) (with-arena tmp (& flag))]
    [rc : (& c char) (with-arena tmp (& c))]
    [rw : (& w i32) (with-arena tmp (& w))]
    [rp : (& p Pair) (with-arena tmp (& p))]
    [ry : (& p i64) (with-arena tmp (& p.y))]
    [rb : (& q i32) (with-arena tmp (& q.b))]
    (clobber-arena)
    (unless (= (deref rn) 42) (return 1))
    (unless (= (deref rf) 2.5) (return 2))
    (unless (deref rflag) (return 3))
    (unless (= (deref rc) 'Z') (return 4))
    (unless (= (deref rw) -9) (return 5))
    (unless (= (+ (deref rp).x (deref rp).y) 23) (return 6))
    (unless (= (deref ry) 12) (return 7))
    (unless (= (deref rb) 22) (return 8))
    0))

;; Nested regions, a call that returns its argument reference, a holder that
;; carries the reference out, and a parameter.
(define (case-shapes [k : i64]) : i64
  (let
    [n : i64 (+ k 30)]
    [p : Pair (Pair k (+ k 1))]
    [nested : (& n i64)
      (with-arena
        outer
        (let
          [inner-ref : (& n i64) (with-arena inner (& n))]
          (clobber-arena)
          inner-ref))]
    [through : (& n i64) (with-arena tmp (same-ref (& n)))]
    [held : (Holder p) (Holder 5 (with-arena tmp (& p.x)))]
    [param : (& k i64) (with-arena tmp (& k))]
    (clobber-arena)
    (unless (= (deref nested) 42) (return 11))
    (unless (= (deref through) 42) (return 12))
    (unless (= (+ held.tag (deref held.r)) 17) (return 13))
    (unless (= (deref param) 12) (return 14))
    0))

;; One borrow site runs on every iteration; earlier references from it stay
;; live while the local is unchanged.
(define (case-loop) : i64
  (let
    [n : i64 42]
    [refs : (Array (& n i64) 4) (array (& n) (& n) (& n) (& n))]
    [i : i64 0]
    [total : i64 0]
    (while (< i 4)
      (set! (array-ref refs i) (with-arena tmp (& n)))
      (clobber-arena)
      (set! i (+ i 1)))
    (set! i 0)
    (while (< i 4)
      (set! total (+ total (deref (array-ref refs i))))
      (set! i (+ i 1)))
    (unless (= total 168) (return 21))
    ;; A loop-carried local is borrowed afresh after each update.
    (let
      [m : i64 0]
      [sum : i64 0]
      (while (< m 5)
        (let
          [r : (& m i64) (with-arena tmp (& m))]
          (clobber-arena)
          (set! sum (+ sum (deref r))))
        (set! m (+ m 1)))
      (unless (= sum 10) (return 22)))
    0))

;; A scalar payload bound through a shared reference.
(define (case-payload [o : (& Opt)]) : i64
  (match o
    [(Some v)
      (let
        [r : (& v i64) (with-arena tmp (& v))]
        (clobber-arena)
        (deref r))]
    [(None) 0]))

;; `in-arena` allocates into a first-class arena that is then destroyed.
(define (case-in-arena) : i64
  (let
    [n : i64 42]
    [p : Pair (Pair 3 4)]
    [owner (arena.make)]
    [r : (& n i64) (in-arena owner (& n))]
    [rx : (& p i64) (in-arena owner (& p.y))]
    (arena.destroy-safe! owner)
    (clobber-arena)
    (unless (= (deref r) 42) (return 31))
    (unless (= (deref rx) 4) (return 32))
    0))

;; No borrow of a local allocates: explicit borrows, a field of a packed
;; local, an implicit borrow at a call and a borrow site in a loop.
(define (case-no-alloc) : i64
  (let
    [n : i64 40]
    [f : f64 1.5]
    [flag : bool true]
    [c : char 'q']
    [p : Pair (Pair 1 2)]
    [q : Narrow (Narrow 3 4)]
    [before : i64 (profile.alloc-total)]
    [rn : (& n i64) (& n)]
    [rf : (& f f64) (& f)]
    [rflag : (& flag bool) (& flag)]
    [rc : (& c char) (& c)]
    [rp : (& p Pair) (& p)]
    [rx : (& p i64) (& p.x)]
    [rq : (& q Narrow) (& q)]
    [rb : (& q i32) (& q.b)]
    [called : i64 (read-ref n)]
    [i : i64 0]
    [looped : i64 0]
    (while (< i 8)
      (set! looped (+ looped (read-ref (& n))))
      (set! i (+ i 1)))
    (let
      [after : i64 (profile.alloc-total)]
      (unless (= after before) (return 41))
      (unless (= (+ (deref rn) (deref rx)) 41) (return 42))
      (unless (= (deref rf) 1.5) (return 43))
      (unless (= (deref rp).y 2) (return 44))
      (unless (= (+ called looped) 360) (return 45))
      (unless (and (deref rflag) (= (deref rc) 'q')) (return 46))
      (unless (= (+ (deref rq).a (deref rb)) 7) (return 47))
      0)))

(define (main) : i64
  (let
    [some : Opt (Some 42)]
    [none : Opt (None)]
    (unless (= (case-kinds) 0) (return (case-kinds)))
    (unless (= (case-shapes 12) 0) (return (case-shapes 12)))
    (unless (= (case-loop) 0) (return (case-loop)))
    (unless (= (case-payload (& some)) 42) (return 51))
    (unless (= (case-payload (& none)) 0) (return 52))
    (unless (= (case-in-arena) 0) (return (case-in-arena)))
    (unless (= (case-no-alloc) 0) (return (case-no-alloc)))
    42))