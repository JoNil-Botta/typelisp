;; A move-only value read through a reference is a view: its binder (a `let`
;; or a `match` pattern binder, in or out of tail position) is the referent's
;; storage, and a borrow of it is a reborrow of the referent with the
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

(defstruct Out
  (e E)
  (s In))

(define (field-view [p : (& p Out)]) : (& p In)
  (let
    [v p.s]
    (& v)))

(define (tail-pattern-view [p : (& p Out)]) : (& p In)
  (match p.e
    [(A x) (& x)]
    [(B _) (& p.s)]))

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
    [o : Out (Out (E.A (In (box 40) 1 2)) (In (box 2) 3 4))]
    [s (field-view (& o))]
    [t (tail-pattern-view (& o))]
    [u (pattern-view (& o))]
    [junk : i64 (clobber 100 200 300 400 500 600 700 800)]
    (if (and
      (= junk 900)
      (= s.n 3)
      (= (deref s.b) 2)
      (= t.m 2)
      (= (deref t.b) 40)
      (= u.n 1)
      (= (deref u.b) 40))
      42
      1)))