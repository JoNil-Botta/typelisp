;: A `let`-bound `&mut` borrow through a local shared reference is rejected
;: like a call argument (#8694).
(define (bump [q : (&mut i64)]) : unit
  (set! (deref q) (+ (deref q) 1)))

(define (main) : i64
  (let
    [n : i64 40]
    [r (& n)]
    [m (&mut r)]
    (bump m)
    n))