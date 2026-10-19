;: Two copies of one shared reference must not both write the `&mut` they
;: reach (#8696).
(defstruct Pt
  (name String)
  (x i64))

(define (sneak2 [a : (& (Tuple (&mut Pt) i64))] [b : (& (Tuple (&mut Pt) i64))]) : i64
  (let
    [first (replace! (deref (tuple-ref (deref a) 0)) (Pt "first" 10))]
    [second (replace! (deref (tuple-ref (deref b) 0)) (Pt "second" 20))]
    (+ first.x second.x)))

(define (alias [m : (&mut m Pt)]) : i64
  (let
    [t : (Tuple (&mut m Pt) i64) (tuple m 1)]
    (sneak2 (& t) (& t))))

(define (main) : i64
  (let
    [point (Pt "abc" 12)]
    [result (alias (&mut point))]
    (+ result point.x)))