(defenum Status
  (Idle)
  (Scored i64)
  (Moved i64 (Array i64 2))
  (Wide i64 i64 i64 i64 i64 i64 i64 i64 i64))

(define (idle) : Status
  (Status.Idle))

(define (scored [value : i64]) : Status
  (Status.Scored value))

(define (moved) : Status
  (Status.Moved 123 (array 9 10)))

(define (wide) : Status
  (Status.Wide 1 2 3 4 5 6 7 8 9))

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

(define (wide? [status : Status]) : bool
  (match status
    [(Wide a b c d e f g h i)
      (and
        (= a 1)
        (= b 2)
        (= c 3)
        (= d 4)
        (= e 5)
        (= f 6)
        (= g 7)
        (= h 8)
        (= i 9))]
    [_ false]))