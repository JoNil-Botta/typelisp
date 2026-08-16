(module semantic.lsp_cache.open_consumer)

(import semantic.lsp_cache.shared)

(define (open-consumer) : i64
  (+ shared.target-value 1))