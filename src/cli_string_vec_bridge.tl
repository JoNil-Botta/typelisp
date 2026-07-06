;; Transitional bridge for CLI-owned generated string vectors that still call
;; driver/test internals expecting the legacy stdlib.vector StringVec API.
(import stdlib.vector)
(import (vector.vector String) as cli_svec)

(define (cli-string-vec-to-legacy [roots : (& roots cli_svec.Vec)]) : vector.StringVec
  (let
    [count : i64 (cli_svec.len roots)]
    [index : i64 0]
    [legacy : vector.StringVec (vector.string-vec-new)]
    (begin
      (while (< index count)
        (begin
          (set!
            legacy
            (vector.string-vec-push legacy (cli_svec.get roots index "")))
          (set! index (+ index 1))))
      legacy)))