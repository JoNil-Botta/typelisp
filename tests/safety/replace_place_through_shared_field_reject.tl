;: A struct field `&mut` behind a shared reference is not writable (#8696).
(defstruct Pt
  (name String)
  (x i64))

(defstruct Holder
  (m (&mut program Pt)))

(define (sneak [h : (& Holder)]) : Pt
  (replace! (deref (deref h).m) (Pt "z" 2)))

(define (main) : i64
  42)