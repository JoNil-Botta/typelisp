;; The public shallow-view helper must preserve array bounds checks before its
;; representation-level read.
(import stdlib.process)
(import stdlib.string)

(define (main) : i64
  (let
    [slots : (__tl_dyn-array String) (__tl_make-array String 0)]
    [value : String (process.process-array-shared-view slots 0)]
    (string.string-length (& value))))