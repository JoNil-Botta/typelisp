;; compiler_parse.tl - runnable smoke driver for compiler_parse_core.tl (#335).

(import "compiler_parse_core.tl")

(define (main) : i64
  (compiler-parse-smoke))
