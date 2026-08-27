;: A mutable-reference capture ends after the closure's final direct call in a
;: let initializer, before the body reads the owner.

(define (main) : i64
  (let
    [values : (Array i64 1) (array 41)]
    [exclusive : (&mut values (Array i64 1)) (&mut values)]
    [bump : (-> unit)
      (lambda () : unit
        (set! (array-ref exclusive 0) 42))]
    [ignored : unit (bump)]
    (if (= (array-ref values 0) 42)
      42
      1)))