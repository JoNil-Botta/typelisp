;; #9257 repro: `stdlib.process/process-env-list-shared-view` must not exist.
(import stdlib.process)
(import stdlib.string)

(define (main) : i64
  (let
    [env : process.ProcessEnvList
      (process.env-cons "A" "one" (process.env-empty))]
    [alias : process.ProcessEnvList
      (process.process-env-list-shared-view (& env))]
    [shared (& env)]
    (set! (array-ref alias.values 0) "changed")
    (if (string.eq (& (array-ref shared.values 0)) "changed")
      42
      1)))