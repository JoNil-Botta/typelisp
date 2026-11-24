;; #9257: `stdlib.process_runtime/process-runtime-string-array-shared-view` must not exist.
(import stdlib.process_runtime)
(import stdlib.string)

(define (main) : i64
  (let
    [slots : (__tl_dyn-array String) (__tl_make-array String 1)]
    [value : String
      (process_runtime.process-runtime-string-array-shared-view (& slots) 0)]
    (string.string-length (& value))))