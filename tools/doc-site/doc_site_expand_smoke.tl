;; doc_site_expand_smoke.tl - Smoke for generated-module site sections.
(import "doc_site_expand_pages_core.tl")

(define (main) : i64
  (let
    [sections : String (doc-site-expand-generated-sections "stdlib/vector.tl")]
    (if (and
      (doc-string-contains? sections "stdlib.vector.generated.i64")
      (doc-string-contains? sections "generated-module-import")
      (doc-string-contains? sections "ivec")
      (doc-string-contains? sections "<h3><a href=\"#tl-Vec\">Vec</a></h3>")
      (doc-string-contains? sections "<h3><a href=\"#tl-new\">new</a></h3>")
      (doc-string-contains? sections "<h3><a href=\"#tl-len\">len</a></h3>")
      (doc-string-contains? sections "<h3><a href=\"#tl-push\">push</a></h3>"))
      42
      (panic "doc-site-expand: generated vector smoke mismatch"))))