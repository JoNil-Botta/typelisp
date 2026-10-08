;: The struct referent of a local shared reference cannot be borrowed mutably
;: (#8694).
(defstruct Pt
  (name String)
  (x i64))

(define (bump [q : (&mut Pt)]) : unit
  (set! q.x (+ q.x 1)))

(define (main) : i64
  (let
    [p (Pt "a" 40)]
    [r (& p)]
    (bump (&mut r))
    p.x))