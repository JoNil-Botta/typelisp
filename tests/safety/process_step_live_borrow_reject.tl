(import stdlib.process)

; The step owns its value, so taking its tail cannot leave a live value borrow.
(define (main) : i64
  (let
    [step : process.ProcessStringStep
      (process.string-step (process.args-single "arg"))]
    [value : (& step str) (process.string-step-value step)]
    [tail : process.ProcessStringList (process.string-step-rest step)]
    (+ (string-length value) (process.args-count tail))))