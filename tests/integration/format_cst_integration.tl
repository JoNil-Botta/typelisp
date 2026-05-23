;; Self-hosted formatter token/CST smoke test (#326).
(import "format_cst.tl")

(define (main) : i64
  (format-cst-self-test))
