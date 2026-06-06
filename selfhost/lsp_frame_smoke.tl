;; lsp_frame_smoke.tl - Runnable smoke for LSP diagnostic metadata adapters.
(import "lsp_frame_core.tl")

(define (main) : i64
  (lsp-diagnostic-metadata-smoke))