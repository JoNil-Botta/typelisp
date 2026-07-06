;; Transitional bridge between CLI-owned generated string vectors and legacy
;; stdlib.vector StringVec APIs at driver/test/LSP boundaries.
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

(define (cli-string-vec-from-legacy [roots : (& roots vector.StringVec)]) : cli_svec.Vec
  (let
    [count : i64 (vector.string-vec-len roots)]
    [index : i64 0]
    [generated : cli_svec.Vec (cli_svec.new)]
    (begin
      (while (< index count)
        (begin
          (cli_svec.push
            (&mut generated)
            (vector.string-vec-get roots index ""))
          (set! index (+ index 1))))
      generated)))