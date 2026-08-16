(module semantic.lsp_cache.noise)

;; Same spelling, different canonical module identity.
(define target-value : i64
  99)

(define (noise-consumer) : i64
  target-value)