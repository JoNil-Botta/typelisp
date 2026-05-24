;; Self-hosted formatter special-form rule smoke test (#367).

(import "format_rules.tl")

(define (main) : i64
  (format-rules-self-test))