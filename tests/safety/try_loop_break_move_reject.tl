(defenum Step
  (Ok i64)
  (Err i64))

(defstruct Token
  (id i64)
  (name String))

(define (consume [t : Token]) : i64
  t.id)

;: The break inside the try operand leaves the loop with `t` moved, so the
;: use after the loop is a second move.
(define (bad [t : Token] [flag : bool]) : Step
  (begin
    (while true
      (begin
        (try
          (if flag
            (begin
              (consume t)
              (break))
            (Step.Ok 1)))
        (break)))
    (Step.Ok (consume t))))

(define (main) : i64
  0)