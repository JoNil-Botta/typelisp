;; lsp_frame.tl - Retained selfhost LSP compatibility/coverage driver.
;;
;; The published entry point is `selfhost/cli.tl lsp`. This thin wrapper stays
;; as a focused LSP frame compile target for manifest coverage.
(import "lsp_frame_core.tl")

(define (main) : i64
  (lsp-frame-run))