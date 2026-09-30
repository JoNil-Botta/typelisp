(defstruct Token
  (id i64)
  (name String))

(define (consume [t : Token]) : i64
  t.id)

(define (pick [n : i64] [x : Token] [z : Token]) : i64
  (let
    [chosen : Token (cond [(= n 0) x] [else z])]
    (+ (consume chosen) (consume x))))

(define (main) : i64
  42)