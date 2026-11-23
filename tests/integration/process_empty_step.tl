(import stdlib.process)

(define (main) : i64
  (let
    [step : process.ProcessStringStep
      (process.string-step (process.args-empty))]
    (if (process.string-step-present? step)
      1
      42)))