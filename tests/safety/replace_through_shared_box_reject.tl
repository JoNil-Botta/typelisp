;; A `&mut` inside a box reached through a shared reference grants only shared
;; access (Rust E0594): replace! cannot write its referent.
(defstruct Pt
  (name String)
  (x i64))

(define (sneak [h : (& h (Box (Tuple (&mut a Pt) i64)))]) : Pt
  (replace! (deref (tuple-ref (deref (deref h)) 0)) (Pt "z" 2)))

(define (main) : i64
  42)