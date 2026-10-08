;: An element of `(deref r)` with `r` a shared reference cannot be borrowed
;: mutably: the deref keeps the shared path (#8694, the `&mut` form of #8577).
(define (bump [q : (&mut i64)]) : unit
  (set! (deref q) (+ (deref q) 1)))

(define (f [r : (& (Array i64 2))]) : i64
  (bump (&mut (array-ref (deref r) 0)))
  (array-ref (deref r) 0))

(define (main) : i64
  (let
    [a (make-array i64 2)]
    (set! (array-ref a 0) 40)
    (f (& a))))