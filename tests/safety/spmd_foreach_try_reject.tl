;: SPEC SPMD contract: foreach bodies do not support try-style early exits.
(import stdlib.array)
(import stdlib.result)
(import (result i64 i64) as result_i64_i64)

(define (main [out : (Array i64)] [flag : bool] [n : i64]) : result_i64_i64.Result
  (begin
    (foreach
      ([i : i64 0 n])
      (array-set!
        out
        i
        (try
          (if flag
            (result_i64_i64.ok 1)
            (result_i64_i64.err i)))))
    (result_i64_i64.ok 0)))