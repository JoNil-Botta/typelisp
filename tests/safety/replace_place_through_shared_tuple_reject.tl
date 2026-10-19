;: A `&mut` stored in a tuple behind a shared reference grants only shared
;: access, so `replace!` cannot write through it (#8696).
(defstruct Pt
  (name String)
  (x i64))

(define (sneak [h : (& (Tuple (&mut Pt) i64))]) : Pt
  (replace! (deref (tuple-ref (deref h) 0)) (Pt "z" 2)))

(define (main) : i64
  42)