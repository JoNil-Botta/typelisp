;: A shared reference stored as an array element makes a `&mut` reborrow of
;: the place it reaches shared (#8696).
(defstruct Pt
  (name String)
  (x i64))

(define (bump [q : (&mut q Pt)]) : unit
  (set! q.x (+ q.x 1)))

(define (sneak [h : (&mut (Array (& (&mut Pt)) 1))]) : unit
  (bump (&mut (deref (deref (array-ref (deref h) 0))))))

(define (main) : i64
  42)