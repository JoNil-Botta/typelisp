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
        "<h3><a href=\"#tl-stdlib_2evector_2egenerated_2ei64.defstruct.Vec.generated.")
      (doc_site_expand_pages_core.doc-site-expand-string-contains?
        vector-sections
        "<h3><a href=\"#tl-stdlib_2evector_2egenerated_2ei64.define-function.new.generated.")
      (doc_site_expand_pages_core.doc-site-expand-string-contains?
        vector-sections
        "<h3><a href=\"#tl-stdlib_2evector_2egenerated_2ei64.define-function.len.generated.")
      (doc_site_expand_pages_core.doc-site-expand-string-contains?
        vector-sections
        "<h3><a href=\"#tl-stdlib_2evector_2egenerated_2ei64.define-function.push-ref_21.generated.")
      (doc_site_expand_pages_core.doc-site-expand-string-contains?
        vector-sections
        "<h3><a href=\"#tl-stdlib_2evector_2egenerated_2ei64.defmacro.push_21.generated.")
      (doc_site_expand_pages_core.doc-site-expand-string-contains?
        vector-sections
        "tl-stdlib_2evector_2egenerated_2ei64.field.len.Vec.generated.")
      (doc_site_expand_pages_core.doc-site-expand-string-contains?
        vector-sections
        "tl-stdlib_2evector_2egenerated_2ei64.enum-variant.Ok.Pop.generated.")
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
        "<span class=\"tl-syn-call\">__tl_dyn-array</span> <span class=\"tl-syn-type\">i64</span>")
      (not
        (doc_site_expand_pages_core.doc-site-expand-string-contains?
          queue-sections
          "<span class=\"tl-syn-type\">Array</span> <span class=\"tl-syn-type\">i64</span>)")))
      42
      (io.panic "doc-site-expand: generated collection smoke mismatch"))))