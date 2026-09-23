(defstruct Token
  (id i64)
  (name String))

(define (consume [t : Token]) : i64
  t.id)

(define (pick [flag : bool]) : i64
  (let
    [t : Token (Token 1 "t")]
    [spent : i64 (consume t)]
    (begin
      (if flag
        (return spent)
        (set! t (Token 41 "fresh")))
      (+ (consume t) spent))))

(define (main) : i64
  (pick false))