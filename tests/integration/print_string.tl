;; print_string.tl — write whole String values through the canonical formatter.
;; Each `(io.print-format "{}" s)` call issues one stdout write. The "\n"
;; escape lexes to a real newline byte, so this
;; emits exactly "hello\nworld\n" to stdout and exits 0.
(import stdlib.io)

(define (main) : i64
  (begin
    (io.print-format "{}" "hello\n")
    (io.print-format "{}" "world\n")
    0))