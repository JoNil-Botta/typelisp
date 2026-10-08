;: A field reached through a shared reference cannot be borrowed mutably, in a
;: call argument or a `let` (#8694).
(defstruct Pt
  (name String)
  (x i64))

(define (bump [q : (&mut i64)]) : unit
  (set! (deref q) (+ (deref q) 1)))

(define (main) : i64
  (let
    [p (Pt "a" 40)]
    [r (& p)]
    (bump (&mut r.x))
    p.x))