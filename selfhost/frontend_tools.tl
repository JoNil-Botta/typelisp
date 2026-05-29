;; frontend_tools.tl - Selfhost tokenize/parse CLI driver (#796).
(import "frontend_tools_core.tl")

(define (main) : i64
  (front-cli-main))