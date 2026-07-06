;; doc_md_smoke.tl - Runnable smoke for doc_md.tl: exercises the block
;; scanner (heading / paragraph / quote / lists / fence / table) and inline-span
;; renderer, then returns 42.
(import doc_md)

(define (main) : i64
  (doc_md.compiler-doc-md-self-test))