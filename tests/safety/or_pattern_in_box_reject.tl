(defenum Width
  (Narrow i64)
  (Wide i64))

(defenum Holder
  (Hold (Box Width)))

(define (width [holder : Holder]) : i64
  (match holder
    [(Hold (box (or (Narrow n) (Wide n)))) n]))

(define (main) : i64
  0)