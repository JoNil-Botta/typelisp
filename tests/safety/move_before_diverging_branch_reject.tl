(defstruct Token
  (id i64)
  (name String))

(define (consume [t : Token]) : i64
  t.id)

(define (pick [flag : bool]) : i64
  (let
    [t : Token (Token 41 "t")]
    [spent : i64 (consume t)]
    (begin
      (if flag
        (return spent)
        unit)
      (+ (consume t) spent))))

(define (main) : i64
  (pick false))