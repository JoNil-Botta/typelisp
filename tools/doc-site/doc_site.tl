;; doc_site.tl - Static stdlib/API HTML site builder CLI (#964).
;;
;; Usage through the current compiler runner:
;;   typelisp run tools/doc-site/doc_site.tl -- target/site
(import "../../stdlib/io.tl")

(import "doc_site_core.tl")

(define (doc-site-usage) : i64
  (begin
    (print-error "doc-site: expected zero args or output directory")
    1))

(define (main) : i64
  (if (= (arg-count) 1)
    (doc-site-build "target/site")
    (if (= (arg-count) 2)
      (doc-site-build (arg 1))
      (doc-site-usage))))