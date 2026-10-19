;: A shared reference in the middle of a deref chain makes the rest of the
;: place shared, even when the outer and inner references are mutable (#8696).
(defstruct Pt
  (name String)
  (x i64))

(define (sneak [h : (&mut (& (&mut Pt)))]) : Pt
  (replace! (deref (deref (deref h))) (Pt "z" 2)))

(define (main) : i64
  42)