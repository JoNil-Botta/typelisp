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
        (begin
          (consume t)
          unit)
        unit)
      (+ (consume t) 1))))

(define (main) : i64
  (pick false))