;: Generated result modules reject try propagation when error payloads differ.
(import "stdlib/string.tl")
(import stdlib.result)
(import (result i64 String) as result_i64_string)
(import (result i64 i64) as result_i64_i64)

(define (read-text [ok : bool]) : result_i64_string.Result
  (if ok
    (result_i64_string.ok 41)
    (result_i64_string.err "bad")))

(define (bad [ok : bool]) : result_i64_i64.Result
  (let
    [value : i64 (try (read-text ok))]
    (result_i64_i64.ok value)))

(define (main) : i64
  (result_i64_i64.value-or (bad true) 0))