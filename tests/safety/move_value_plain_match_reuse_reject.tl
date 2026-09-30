(defstruct Token
  (id i64)
  (name String))

(define (consume [t : Token]) : i64
  t.id)

(define (pick [n : i64] [x : Token] [z : Token]) : i64
  (+
    (consume
      (match n
        [0 x]
        [_ z]))
    (consume z)))

(define (main) : i64
  42)