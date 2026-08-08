;: A try operand cannot move its Result owner from a global place.
(import stdlib.result)
(import (result.result String i64) as global_result)

(define global-result : global_result.Result
  (global_result.ok "owned"))

(define (take-global) : global_result.Result
  (global_result.ok (try global-result)))

(define (main) : i64
  42)