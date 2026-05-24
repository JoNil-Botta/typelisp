(define (noop) : unit
  unit)

(define (branch-unit [b : bool]) : unit
  (if b
    unit
    unit))

(define (main) : i64
  (begin
    (let
      [x : unit unit]
      x)
    (noop)
    (branch-unit true)
    7))