;; compile_profile_result_import.tl - generated result imports should not force
;; an extra module-placeholder fixed-point pass.
(import stdlib.result)
(import (result.result i64 String) as result_i64_string)

(define (main) : i64
  42)