(module unreachable_cli_helper_lib)

(import stdlib.io)

(define (unused-cli-helper) : unit
  (begin
    (io.print-string "unused")
    (io.print-newline)))

(define (reachable-helper [x : i64]) : i64
  (+ x 1))
