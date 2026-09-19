(defstruct Token
  (id i64)
  (name String))

(define (consume [t : Token]) : i64
  t.id)

(define (pick [flag : bool]) : i64
  (let
    [t : Token (Token 41 "t")]
    (begin
      (if flag
        (return (consume t))
        unit)
      (+ (consume t) 1))))

(define (main) : i64
  (if (= (pick true) 41)
    (pick false)
    1))