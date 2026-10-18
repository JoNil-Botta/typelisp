;: An array element `&mut` behind a shared reference is not writable (#8696).
(defstruct Pt
  (name String)
  (x i64))

(define (sneak [h : (& (Array (&mut Pt) 1))]) : Pt
  (replace! (deref (array-ref (deref h) 0)) (Pt "z" 2)))

(define (main) : i64
  42)