;; #9077 repro 4: `replace!` reserves `p.x`, so an implicit mutable reborrow
;; of `p` while evaluating the replacement value conflicts with it (Rust
;; E0499). Main 8d29b08a1 accepted it.
(defstruct Pt
  (name String)
  (x i64))

(define (bump [q : (&mut q Pt)]) : unit
  (set! q.x (+ q.x 1)))

(define (g [p : (&mut p Pt)]) : i64
  (replace!
    p.x
    (begin
      (bump p)
      5)))

(define (main) : i64
  (let
    [pt (Pt "abc" 40)]
    (+ 40 (g (&mut pt)))))