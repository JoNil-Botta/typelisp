;; A copyable value read through a reference is a copy taken at the read: a
;; later write to the owner does not change it, for a `let` binder and for a
;; pattern binder of a view's match (main read the rewritten storage here).
(defstruct C
  (k i64)
  (n i64)
  (m i64))

(defenum E
  (A C)
  (B i64))

(defstruct Out
  (e E)
  (s C))

(define (let-copy) : i64
  (let
    [o : Out (Out (E.B 0) (C 42 1 2))]
    [rr (& o)]
    [v rr.s]
    (set! o.s.k 9)
    v.k))

(define (pattern-copy) : i64
  (let
    [o : Out (Out (E.A (C 42 1 2)) (C 0 0 0))]
    [rr (& o)]
    (match rr.e
      [(A x)
        (begin
          (set! o.e (E.A (C 9 9 9)))
          x.k)]
      [(B _) 0])))

;; A copyable payload bound by a match on a `&mut` view is a copy too, even
;; when a move-only sibling is written through (the view is then mutable):
;; rewriting the matched part afterwards does not change it.
(defstruct Wide
  (k i64)
  (j i64)
  (l i64))

(defstruct Owned
  (b (Box i64))
  (n i64)
  (m i64))

(defenum Pair
  (Both Owned Wide)
  (Other i64 i64 i64 i64 i64 i64))

(defstruct PairOut
  (e Pair)
  (t i64))

(define (mutable-view-copy [p : (&mut p PairOut)]) : i64
  (match p.e
    [(Both x c)
      (begin
        (set! x.n 9)
        (set! p.e (Pair.Other 7 7 7 7 7 7))
        c.k)]
    [(Other _ _ _ _ _ _) 0]))

;; A copyable aggregate holding a reference is a copy too, and may be
;; borrowed while it lives.
(defstruct Holder
  (:lifetimes q)
  (r (& q i64))
  (a i64)
  (b i64))

(defstruct HolderOut
  (:lifetimes q)
  (h (Holder q))
  (t i64))

(define (holder-sum [h : (& x (Holder q))]) : i64
  (+ h.a h.b (deref h.r)))

(define (holder-local [p : (& p (HolderOut q))]) : i64
  (let
    [v p.h]
    [r (& v)]
    (holder-sum r)))

(define (main) : i64
  (let
    [n : i64 39]
    [o (HolderOut (Holder (& n) 1 2) 3)]
    (if (and
      (= (let-copy) 42)
      (= (pattern-copy) 42)
      (= (holder-local (& o)) 42)
      (=
        (mutable-view-copy
          (&mut (PairOut (Pair.Both (Owned (box 1) 1 1) (Wide 42 5 6)) 3)))
        42))
      42
      1)))