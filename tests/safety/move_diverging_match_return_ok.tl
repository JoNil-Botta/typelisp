(defstruct Token
  (id i64)
  (name String))

(define (consume [t : Token]) : i64
  t.id)

(defenum Mode
  (Fast)
  (Slow))

(define (pick [mode : Mode]) : i64
  (let
    [t : Token (Token 41 "t")]
    (begin
      (match mode
        [(Mode.Fast) (return (consume t))]
        [(Mode.Slow) unit])
      (+ (consume t) 1))))

(define (main) : i64
  (if (= (pick (Mode.Fast)) 41)
    (pick (Mode.Slow))
    1))