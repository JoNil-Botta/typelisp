;; Self-hosted formatter special-form rule smoke test.
(import "../format_rules.tl")
(import "../format_rules_doc_compat.tl")

(define (main) : i64
  (let
    [rules : i64 (format-rules-self-test)]
    [compat : i64 (format-rules-doc-compat-self-test)]
    (if (= rules 42)
      compat
      rules)))