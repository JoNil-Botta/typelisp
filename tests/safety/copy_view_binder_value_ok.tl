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

(define (main) : i64
  (if (and (= (let-copy) 42) (= (pattern-copy) 42))
    42
    1))