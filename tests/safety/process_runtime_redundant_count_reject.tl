;; Runtime argv storage also derives its count from the backing array.
(import stdlib.process_runtime)

(define (main) : i64
  (let
    [slots : (__tl_dyn-array String) (__tl_make-array String 0)]
    [args : process_runtime.ProcessRuntimeStringList
      (process_runtime.ProcessRuntimeStringList slots 99)]
    (process_runtime.args-count args)))