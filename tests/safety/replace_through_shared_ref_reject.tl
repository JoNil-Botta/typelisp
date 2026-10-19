;; A `&mut` behind a `&` grants only shared access (Rust E0594): replace!
;; cannot write its referent.
(defstruct Pt
  (name String)
  (x i64))

(define (sneak [h : (& h (&mut a Pt))]) : Pt
  (replace! (deref (deref h)) (Pt "z" 2)))

(define (main) : i64
  42)