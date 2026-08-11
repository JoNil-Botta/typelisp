(define (main) : i64
  (let
    [values : (Array i64 1) (array 0)]
    [exclusive : (&mut values (Array i64 1)) (&mut values)]
    [make-bump : (-> (-> unit))
      (lambda () : (-> unit)
        (lambda () : unit
          (set! (array-ref exclusive 0) 1)))]
    [bump : (-> unit) (make-bump)]
    (begin
      (bump)
      0)))