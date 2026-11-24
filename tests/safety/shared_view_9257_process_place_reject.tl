;; #9257: `stdlib.process/process-place-shared-view` must not exist.
(import stdlib.process)

(define (main) : i64
  (let
    [env : process.ProcessEnvList (process.env-empty)]
    [_alias : process.ProcessEnvList (process.process-place-shared-view env)]
    0))