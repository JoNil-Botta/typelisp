;: A Copy field reached through a shared reference is not writable either
;: (#8696).
(defstruct Pt
  (name String)
  (x i64))

(define (sneak [h : (& (Tuple (&mut Pt) i64))]) : i64
  (replace! (deref (tuple-ref (deref h) 0)).x 5))

(define (main) : i64
  42)