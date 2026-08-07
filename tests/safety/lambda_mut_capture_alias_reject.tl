(define (main) : unit
  (let
    [values : (Array i64 1) (array 0)]
    [exclusive : (&mut values (Array i64 1)) (&mut values)]
    [bump : (-> unit)
      (lambda () : unit
        (array-set! exclusive 0 1))]
    [alias : (-> unit) bump]
    (alias)))