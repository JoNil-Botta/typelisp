;; doc_site_expand_pages.tl - CLI wrapper for generated-module site sections.
(import "../../stdlib/io.tl")
(import "doc_site_expand_pages_core.tl")

(define (doc-site-expand-usage) : i64
  (begin
    (print-error "doc-site-expand: expected output directory")
    1))

(define (main) : i64
  (if (= (arg-count) 2)
    (doc-site-expand-pages (arg 1))
    (doc-site-expand-usage)))