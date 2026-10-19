;; A `&mut` element of an array reached through a shared reference grants
;; only shared access (Rust E0594): replace! cannot write its referent.
(defstruct Pt
  (name String)
  (x i64))

(define (sneak [h : (& h (Array (&mut a Pt) 1))]) : Pt
  (replace! (deref (array-ref (deref h) 0)) (Pt "z" 2)))

(define (main) : i64
  42)