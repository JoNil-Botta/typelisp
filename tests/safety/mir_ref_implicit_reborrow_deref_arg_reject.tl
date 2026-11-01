;; #9077 (the #9066 `(deref p)` shape): an explicit `(&mut (deref p))` and an
;; implicit reborrow of `p` in one call alias the same referent (Rust E0499).
;; Main 8d29b08a1 accepted it.
(defstruct Pt
  (name String)
  (x i64))

(define (alias [a : (&mut a Pt)] [b : (&mut b Pt)]) : i64
  (set! a.x 1)
  (set! b.x 2)
  a.x)

(define (g [p : (&mut p Pt)]) : i64
  (alias (&mut (deref p)) p))

(define (main) : i64
  (let
    [pt (Pt "abc" 40)]
    (+ 40 (g (&mut pt)))))