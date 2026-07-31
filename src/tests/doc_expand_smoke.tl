;; doc_expand_smoke.tl - Runnable smoke for generated-module docs.
(import doc_expand)

(define (main) : i64
  (begin
    (doc_expand.doc-expand-ignore-fence-smoke)
    (doc_expand.doc-expand-smoke)))