;; A move-only value read through a reference is a view: its binder (a `let`
;; or a `match` pattern binder of an enum, struct, tuple or catch-all pattern,
;; in or out of tail position, whatever the scrutinee's form) is the
;; referent's storage, and a borrow of it is a reborrow of the referent with the
;; reference's lifetime (SPEC 3.9). Returning it is sound; lowering must not
;; copy the view into the frame (#8889 review: a frame copy was returned and
;; read after the frame was reused).
(defstruct In
  (b (Box i64))
  (n i64)
  (m i64))

(defenum E
  (A In)
  (B i64))

(defstruct Mid
  (i In)
  (k i64))

(defstruct Out
  (e E)
  (s In)
  (mid Mid)
  (pair (Tuple In i64)))

(define (field-view [p : (& p Out)]) : (& p In)
  (let
    [v p.s]
    (& v)))

(define (tail-pattern-view [p : (& p Out)]) : (& p In)
  (match p.e
    [(A x) (& x)]
    [(B _) (& p.s)]))

;; A scrutinee that is not written as a place is still a view by its type.
(define (value-form-view [p : (& p Out)]) : (& p In)
  (match (begin
    p.e)
    [(A x) (& x)]
    [(B _) (& p.s)]))

(define (struct-pattern-view [p : (& p Out)]) : (& p In)
  (match p.mid
    [(Mid i _) (& i)]))

(define (catch-all-view [p : (& p Out)]) : (& p In)
  (match p.s
    [v (& v)]))

(define (tuple-pattern-view [p : (& p Out)]) : (& p In)
  (match p.pair
    [(tuple a _) (& a)]))

(define (pattern-view [p : (& p Out)]) : (& p In)
  (let
    [r : (& p In)
      (match p.e
        [(A x) (& x)]
        [(B _) (& p.s)])]
    r))

;; Reuses the stack below the callers' frames.
(define (clobber
  [a : i64]
  [b : i64]
  [c : i64]
  [d : i64]
  [e : i64]
  [f : i64]
  [g : i64]
  [h : i64]) : i64
  (let
    [x : (Array i64 8) (array a b c d e f g h)]
    (+ (array-ref x 0) (array-ref x 7))))

(define (main) : i64
  (let
    [o : Out
      (Out
        (E.A (In (box 40) 1 2))
        (In (box 2) 3 4)
        (Mid (In (box 5) 6 7) 8)
        (tuple (In (box 9) 10 11) 12))]
    [s (field-view (& o))]
    [t (tail-pattern-view (& o))]
    [u (pattern-view (& o))]
    [w (value-form-view (& o))]
    [x (struct-pattern-view (& o))]
    [y (catch-all-view (& o))]
    [z (tuple-pattern-view (& o))]
    [junk : i64 (clobber 100 200 300 400 500 600 700 800)]
    (if (and
      (= junk 900)
      (= s.n 3)
      (= (deref s.b) 2)
      (= t.m 2)
      (= (deref t.b) 40)
      (= u.n 1)
      (= (deref u.b) 40)
      (= w.m 2)
      (= (deref w.b) 40)
      (= x.n 6)
      (= (deref x.b) 5)
      (= y.m 4)
      (= (deref y.b) 2)
      (= z.n 10)
      (= (deref z.b) 9))
      42
      1)))