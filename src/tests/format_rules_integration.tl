;; Self-hosted formatter special-form rule smoke test.
(import format_rules as rules)
(import format_rules_doc_compat as compat)

(define (main) : i64
  (let
    [rules-status : i64 (rules.format-rules-self-test)]
    [compat-status : i64 (compat.format-rules-doc-compat-self-test)]
    (if (= rules-status 42)
      compat-status
      rules-status)))