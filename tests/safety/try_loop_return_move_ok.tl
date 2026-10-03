(defenum Step
  (Ok i64)
  (Err i64))

(defstruct Token
  (id i64)
  (name String))

(define (consume [t : Token]) : i64
  t.id)

(define (step [take : bool]) : Step
  (if take
    (Step.Ok 1)
    (Step.Err 2)))

;: The move inside the try operand is on a returning path, so it never reaches
;: the loop backedge.
(define (moved-on-return [t : Token] [run : bool] [take : bool]) : Step
  (begin
    (while run
      (begin
        (try
          (if take
            (let
              [n : i64 (consume t)]
              (return (Step.Ok n)))
            (step take)))
        unit))
    (Step.Ok 0)))

(define (main) : i64
  (match (moved-on-return (Token 42 "t") true true)
    [(Step.Ok n) n]
    [(Step.Err e) e]))