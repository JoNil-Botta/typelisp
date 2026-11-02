;; A tuple holder behind another mutable argument cannot keep a by-value call
;; scratch borrow (#8897).
(define (stash!
  [slot : (&mut s (Tuple i64 (&mut a i64)))]
  [item : (&mut a i64)]) : unit
  (set! (tuple-ref (deref slot) 1) item))

(define (main) : i64
  (let
    [value : i64 0]
    [values : (Array i64 2) (make-array i64 2)]
    [slot : (Tuple i64 (&mut values i64)) (tuple 0 (&mut (array-ref values 0)))]
    (stash! (&mut slot) (&mut value))
    (set! (deref (tuple-ref slot 1)) 42)
    value))