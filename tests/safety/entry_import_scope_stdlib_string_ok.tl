;; `(import stdlib.string.*)` in the entry module must not retarget the builtin
;; `slice-view` inside stdlib.str_cat_runtime, which this harness checks from
;; source (#9678).
(import stdlib.str_cat_runtime)
(import stdlib.string.*)

(define (main) : i64
  (+ (string-length (str_cat_runtime.str-cat "a" "b" "c")) 39))