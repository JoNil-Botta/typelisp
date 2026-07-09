(module serialize_enum_fixture)

(defenum Status
  (Idle)
  (Scored i64)
  (Moved i64 (Array i64 2)))

(define (idle) : Status
  (Status.Idle))

(define (scored [value : i64]) : Status
  (Status.Scored value))

(define (moved) : Status
  (Status.Moved 123 (array 9 10)))

(define (idle? [status : Status]) : bool
  (match status
    [Idle true]
    [_ false]))

(define (scored? [status : Status] [expected : i64]) : bool
  (match status
    [(Scored found) (= found expected)]
    [_ false]))

(define (moved? [status : Status]) : bool
  (match status
    [(Moved code values)
      (and (= code 123) (= (array-ref values 0) 9) (= (array-ref values 1) 10))]
    [_ false]))