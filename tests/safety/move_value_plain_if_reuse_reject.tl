(defstruct Token
  (id i64)
  (name String))

(define (consume [t : Token]) : i64
  t.id)

(define (pick [c : bool] [x : Token] [z : Token]) : i64
  (+
    (consume
      (if c
        x
        z))
    (consume x)))

(define (main) : i64
  42)