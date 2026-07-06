;; doc_site_expand_pages.tl - CLI wrapper for generated-module site sections.
(import stdlib.io)
(import doc_site_expand_pages_core)

(define (doc-site-expand-usage) : i64
  (begin
    (io.print-error "doc-site-expand: expected output directory")
    1))

(define (main) : i64
  (if (= (io.arg-count) 2)
    (doc_site_expand_pages_core.doc-site-expand-pages (io.arg 1))
    (doc-site-expand-usage)))