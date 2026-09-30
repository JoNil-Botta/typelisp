;: try cannot leave a foreach-active body.
(defenum Outcome
  (Ok i64)
  (Err i64))

(define (step) : Outcome
  (Outcome.Ok 1))

(define (run) : Outcome
  (begin
    (foreach
      ([i : i64 0 4])
      (foreach-active
        [lane : i64]
        (let
          [x : i64 (try (step))]
          unit)))
    (Outcome.Ok 0)))

(define (main) : i64
  0)