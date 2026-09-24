;; Self-hosted formatter special-form rule smoke test.
(import format_rules as rules)

(define (main) : i64
  (rules.format-rules-self-test))