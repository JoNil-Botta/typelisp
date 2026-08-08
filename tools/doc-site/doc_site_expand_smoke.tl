;; doc_site_expand_smoke.tl - Smoke for generated-module site sections.
(import stdlib.io)
(import doc_site_expand_pages_core)

(define (main) : i64
  (let
    [vector-sections : String
      (doc_site_expand_pages_core.doc-site-expand-generated-sections
        "stdlib/vector.tl")]
    [queue-sections : String
      (doc_site_expand_pages_core.doc-site-expand-generated-sections
        "stdlib/queue.tl")]
    (if (and
      (doc_site_expand_pages_core.doc-site-expand-string-contains?
        vector-sections
        "stdlib.vector.generated.i64")
      (doc_site_expand_pages_core.doc-site-expand-string-contains?
        vector-sections
        "generated-module-import")
      (doc_site_expand_pages_core.doc-site-expand-string-contains?
        vector-sections
        "ivec")
      (doc_site_expand_pages_core.doc-site-expand-string-contains?
        vector-sections
        "<h3><a href=\"#tl-Vec\">Vec</a></h3>")
      (doc_site_expand_pages_core.doc-site-expand-string-contains?
        vector-sections
        "<h3><a href=\"#tl-new\">new</a></h3>")
      (doc_site_expand_pages_core.doc-site-expand-string-contains?
        vector-sections
        "<h3><a href=\"#tl-len\">len</a></h3>")
      (doc_site_expand_pages_core.doc-site-expand-string-contains?
        vector-sections
        "<h3><a href=\"#tl-push-ref-33\">push-ref!</a></h3>")
      (doc_site_expand_pages_core.doc-site-expand-string-contains?
        vector-sections
        "<h3><a href=\"#tl-push-33\">push!</a></h3>")
      (not
        (doc_site_expand_pages_core.doc-site-expand-string-contains?
          vector-sections
          "tl-from-array"))
      (not
        (doc_site_expand_pages_core.doc-site-expand-string-contains?
          vector-sections
          "tl-to-array"))
      (doc_site_expand_pages_core.doc-site-expand-string-contains?
        queue-sections
        "stdlib.queue.deque.generated.i64")
      (doc_site_expand_pages_core.doc-site-expand-string-contains?
        queue-sections
        "(__tl_dyn-array i64)")
      (not
        (doc_site_expand_pages_core.doc-site-expand-string-contains?
          queue-sections
          "(Array i64)")))
      42
      (io.panic "doc-site-expand: generated collection smoke mismatch"))))