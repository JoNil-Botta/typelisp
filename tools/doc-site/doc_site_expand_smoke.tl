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
        "<h3><a href=\"#tl-stdlib_2evector_2egenerated_2ei64.generated.Vec\">Vec</a></h3>")
      (doc_site_expand_pages_core.doc-site-expand-string-contains?
        vector-sections
        "<h3><a href=\"#tl-stdlib_2evector_2egenerated_2ei64.generated.new\">new</a></h3>")
      (doc_site_expand_pages_core.doc-site-expand-string-contains?
        vector-sections
        "<h3><a href=\"#tl-stdlib_2evector_2egenerated_2ei64.generated.len\">len</a></h3>")
      (doc_site_expand_pages_core.doc-site-expand-string-contains?
        vector-sections
        "<h3><a href=\"#tl-stdlib_2evector_2egenerated_2ei64.generated.push-ref_21\">push-ref!</a></h3>")
      (doc_site_expand_pages_core.doc-site-expand-string-contains?
        vector-sections
        "<h3><a href=\"#tl-stdlib_2evector_2egenerated_2ei64.generated.push_21\">push!</a></h3>")
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