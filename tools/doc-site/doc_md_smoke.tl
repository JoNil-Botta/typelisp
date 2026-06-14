;; doc_md_smoke.tl - Runnable smoke for doc_md.tl (#1276): exercises the block
;; scanner (heading / paragraph / quote / lists / fence / table) and inline-span
;; renderer, then returns 42.
(import "doc_md.tl")

(define (main) : i64
  (compiler-doc-md-self-test))