;; Unreachable bindings still require ordinary typechecking.
(import stdlib.io)

(define (invalid) : i64
  (let
    [answer : i64 (io.panic "no result")]
    [wrong : i64 true]
    (+ answer wrong)))

(define (main) : i64
  (invalid))