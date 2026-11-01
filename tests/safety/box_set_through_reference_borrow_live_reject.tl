;: A store through a `&mut` parameter while a reborrow of its referent is
;: live is an assignment to the borrowed place, reported at the reference.
(define (keep [p : (&mut a i64)]) : (&mut a i64)
  p)

(define (fill [p : (&mut a i64)]) : i64
  (let
    [q : (&mut a i64) (keep (&mut (deref p)))]
    (begin
      (set! (deref p) 5)
      (deref q))))

(define (main) : i64
  0)