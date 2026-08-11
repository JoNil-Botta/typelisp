(define (main) : i64
  (let
    [values : (Array i64 1) (array 0)]
    [exclusive : (&mut values (Array i64 1)) (&mut values)]
    [bump : (-> unit)
      (lambda () : unit
        (set! (array-ref exclusive 0) 1))]
    (begin
      (array-ref values 0)
      (bump)
      0)))