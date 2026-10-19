;: `(deref (deref h))` with `h : (& (&mut T))` is not writable (#8696).
(defstruct Pt
  (name String)
  (x i64))

(define (sneak [h : (& (&mut Pt))]) : Pt
  (replace! (deref (deref h)) (Pt "z" 2)))

(define (main) : i64
  42)