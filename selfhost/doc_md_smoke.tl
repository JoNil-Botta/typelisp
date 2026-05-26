;; doc_md_smoke.tl - Runnable smoke for doc_md.tl (#1276): exercises the
;; inline-span renderer (code / emphasis / link / escaping / degenerate marker)
;; and returns 42.
(import "doc_md.tl")

(define (main) : i64
  (compiler-doc-md-self-test))