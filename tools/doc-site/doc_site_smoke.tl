;; doc_site_smoke.tl - Runnable smoke for the static docs site builder.
(import doc_site_core)

(define (main) : i64
  (doc_site_core.doc-site-smoke))