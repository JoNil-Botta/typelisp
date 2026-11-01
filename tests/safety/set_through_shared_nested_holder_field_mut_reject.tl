;; #9096: the holder's `&mut` field reached through a nested struct field of a
;; shared reference (`o.h.r`) is not writable either. Main 8d29b08a1 accepted
;; it and overwrote the caller's `p`, so `main` exited 42.
(defstruct Pt
  (s String)
  (x i64))

(defstruct Hold
  (:lifetimes a)
  (r (&mut a Pt)))

(defstruct Outer
  (:lifetimes a)
  (h (Hold a)))

(define (sneak [o : (& o (Outer a))]) : unit
  (set! (deref o.h.r) (Pt "z" 42)))

(define (main) : i64
  (let
    [p : Pt (Pt "a" 7)]
    (let
      [outer (Outer (Hold (&mut p)))]
      (sneak (& outer)))
    p.x))