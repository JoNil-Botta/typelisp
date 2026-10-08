;: An element of a shared Slice cannot be borrowed mutably (#8694).
(define (bump [q : (&mut i64)]) : unit
  (set! (deref q) (+ (deref q) 1)))

(define (f [items : (& (Slice i64))]) : i64
  (bump (&mut (array-ref items 0)))
  0)

(define (main) : i64
  (let
    [items (make-array i64 2)]
    (f (& items))))