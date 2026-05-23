;; compiler_parse.tl - runnable smoke driver for the real compiler AST parser.

(import "compiler_parse_core.tl")

(define (main) : i64
  (compiler-parse-smoke))
