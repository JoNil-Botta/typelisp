;; lsp_frame.tl - Standalone wrapper for the selfhost LSP stdio server.
(import "lsp_frame_core.tl")

(define (main) : i64
  (lsp-frame-run))