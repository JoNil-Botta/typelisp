(import stdlib.process)

; Taking the environment tail consumes the entire step.
(define (main) : i64
  (let
    [step : process.ProcessEnvStep (process.env-step (process.env-empty))]
    [tail : process.ProcessEnvList (process.env-step-rest step)]
    (+ (process.env-count tail) (string-length (process.env-step-name step)))))