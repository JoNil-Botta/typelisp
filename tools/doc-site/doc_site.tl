;; doc_site.tl - Static stdlib/API HTML site builder CLI.
;;
;; Usage through the current compiler runner:
;;   typelisp run tools/doc-site/doc_site.tl -- target/site
(import stdlib.io)
(import doc_site_core)

(define (doc-site-usage) : i64
  (begin
    (io.print-error "doc-site: expected zero args or output directory")
    1))

(define (main) : i64
  (if (= (io.arg-count) 1)
    (doc_site_core.doc-site-build "target/site")
    (if (= (io.arg-count) 2)
      (doc_site_core.doc-site-build (io.arg 1))
      (doc-site-usage))))