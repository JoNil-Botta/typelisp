(defstruct Token
  (id i64)
  (name String))

(define (consume [t : Token]) : i64
  t.id)

(define (pick [c : bool] [x : Token] [z : Token]) : i64
  (consume
    (if c
      x
      z)))

(define (main) : i64
  (+
    (pick true (Token 40 "left") (Token 1 "right"))
    (pick false (Token 7 "left") (Token 2 "right"))))