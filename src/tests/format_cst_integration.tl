;; Self-hosted formatter token/CST smoke test.
(import format_cst)

(define (main) : i64
  (format_cst.format-cst-self-test))