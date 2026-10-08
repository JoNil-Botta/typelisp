;: A tuple element reached through a shared reference cannot be borrowed
;: mutably (#8694).
(define (bump [q : (&mut i64)]) : unit
  (set! (deref q) (+ (deref q) 1)))

(define (f [r : (& (Tuple i64 i64))]) : i64
  (bump (&mut (tuple-ref r 0)))
  0)

(define (main) : i64
  (let
    [t (tuple 40 0)]
    (f (& t))))