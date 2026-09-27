;; Self-hosted formatter token/CST smoke test.
(import format_tests)

(define (main) : i64
  (format_tests.format-cst-self-test))