(define (main) : i64
  (let
    [values : (Array i64 1) (array 0)]
    [exclusive : (&mut values (Array i64 1)) (&mut values)]
    [bump : (-> unit)
      (lambda () : unit
        (array-set! exclusive 0 1))]
    (begin
      (bump)
      (array-ref exclusive 0))))