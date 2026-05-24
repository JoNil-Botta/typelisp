;; Self-hosted formatter golden + idempotence smoke test (#328).
;;
;; Exercises the same formatter entry point the `format.tl` driver calls
;; (`format-rules-render-source`, default width 80): every representative
;; source must format to its expected output (golden), and re-formatting that
;; expected output must be a no-op (idempotence). Returns 42 on success.
(import "format_rules.tl")

(define (format-golden-ok? [src : String] [expected : String]) : bool
  (if (string-eq (format-rules-render-source src) expected)
      (string-eq (format-rules-render-source expected) expected)
      false))

(define (main) : i64
  (if (format-golden-ok? (format-rules-decls-source) (format-rules-decls-expected))
      (if (format-golden-ok? (format-rules-flow-source) (format-rules-flow-expected))
          (if (format-golden-ok? (format-rules-comments-source) (format-rules-comments-expected))
              42
              3)
          2)
      1))
