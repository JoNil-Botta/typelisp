;; doc_site_expand_smoke.tl - Smoke for generated-module site sections.
(import stdlib.io)
(import doc_site_expand_pages_core)

(define (main) : i64
  (let
    [sections : String
      (doc_site_expand_pages_core.doc-site-expand-generated-sections
        "stdlib/vector.tl")]
    (if (and
      (doc_site_expand_pages_core.doc-site-expand-string-contains?
        sections
        "stdlib.vector.generated.i64")
      (doc_site_expand_pages_core.doc-site-expand-string-contains?
        sections
        "generated-module-import")
      (doc_site_expand_pages_core.doc-site-expand-string-contains?
        sections
        "ivec")
      (doc_site_expand_pages_core.doc-site-expand-string-contains?
        sections
        "<h3><a href=\"#tl-Vec\">Vec</a></h3>")
      (doc_site_expand_pages_core.doc-site-expand-string-contains?
        sections
        "<h3><a href=\"#tl-new\">new</a></h3>")
      (doc_site_expand_pages_core.doc-site-expand-string-contains?
        sections
        "<h3><a href=\"#tl-len\">len</a></h3>")
      (doc_site_expand_pages_core.doc-site-expand-string-contains?
        sections
        "<h3><a href=\"#tl-push-ref-33\">push-ref!</a></h3>")
      (doc_site_expand_pages_core.doc-site-expand-string-contains?
        sections
        "<h3><a href=\"#tl-push-33\">push!</a></h3>"))
      42
      (io.panic "doc-site-expand: generated vector smoke mismatch"))))