(module semantic.lsp_cache.closed_consumer)

(import semantic.lsp_cache.shared as shared)

;; target-value in comments and strings must never become semantic facts.
(define target-text : String
  "target-value")

(define (closed-consumer) : i64
  (+ shared.target-value 2))