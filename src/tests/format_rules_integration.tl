;; Self-hosted formatter special-form rule smoke test.
(import format_tests)

(define (main) : i64
  (format_tests.format-rules-self-test))