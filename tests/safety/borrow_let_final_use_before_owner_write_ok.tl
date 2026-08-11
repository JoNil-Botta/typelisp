;: A mutable borrow can end after its last use in an ordered let initializer,
;: before the body reads the owner.
(import stdlib.array)

(define (main) : i64
  (let
    [values : (Array i64 1) (array 41)]
    [exclusive : (&mut values (Array i64 1)) (&mut values)]
    [ignored : unit (set! (array-ref exclusive 0) 42)]
    (if (= (array-ref values 0) 42)
      42
      1)))