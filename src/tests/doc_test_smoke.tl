;; doc_test_smoke.tl - Runnable smoke for doc_test.tl (extraction + runner).
(import doc_test)

(define (main) : i64
  (doc_test.doc-test-smoke-all))