(import "stdlib/io.tl")

(define (unused-cli-helper) : unit
  (begin
    (print-string "unused")
    (print-newline)))

(define (reachable-helper [x : i64]) : i64
  (+ x 1))