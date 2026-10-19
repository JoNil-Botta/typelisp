;; A `&mut` stored in a tuple reached through a shared reference grants only
;; shared access (Rust E0594): replace! cannot write its referent.
(defstruct Pt
  (name String)
  (x i64))

(define (sneak [h : (& h (Tuple (&mut a Pt) i64))]) : Pt
  (replace! (deref (tuple-ref (deref h) 0)) (Pt "z" 2)))

(define (main) : i64
  42)