(defenum Step
  (Ok i64)
  (Err i64))

(defstruct Token
  (id i64)
  (name String))

(define (consume [t : Token]) : Step
  (Step.Ok t.id))

;: A try operand that falls through reaches the next iteration, so it cannot
;: move an owner carried into the repeated body.
(define (bad [t : Token] [n : i64]) : Step
  (let
    [i : i64 0]
    (begin
      (while (< i n)
        (begin
          (try (consume t))
          (set! i (+ i 1))))
      (Step.Ok i))))

(define (main) : i64
  0)