;; #9077 repro 3: a `&mut` binder passed as a call argument is an implicit
;; mutable reborrow, so it conflicts with an earlier shared borrow of its
;; referent in the same call (Rust E0502). Main 8d29b08a1 accepted it and the
;; shared `a` observed the write.
(defstruct Pt
  (name String)
  (x i64))

(define (rw [a : (& a Pt)] [b : (&mut b Pt)]) : i64
  (set! b.x 2)
  (deref a).x)

(define (g [p : (&mut p Pt)]) : i64
  (rw (& (deref p)) p))

(define (main) : i64
  (let
    [pt (Pt "abc" 40)]
    (+ 40 (g (&mut pt)))))