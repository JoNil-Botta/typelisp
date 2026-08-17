(import stdlib.io)

(define (unused-cli-helper) : unit
  (begin
    (io.print-format "{}" "unused")
    (io.println "")))

(define (reachable-helper [x : i64]) : i64
  (+ x 1))