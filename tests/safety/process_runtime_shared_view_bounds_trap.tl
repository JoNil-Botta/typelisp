;; Importing the runtime module must not turn its representation-level shallow
;; view into a safe unchecked array read.
(import stdlib.process_runtime)
(import stdlib.string)

(define (main) : i64
  (let
    [slots : (__tl_dyn-array String) (__tl_make-array String 0)]
    [value : String
      (process_runtime.process-runtime-string-array-shared-view (& slots) 0)]
    (string.string-length (& value))))