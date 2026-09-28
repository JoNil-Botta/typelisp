;; doc_test_smoke.tl - Runnable smoke for doc_test.tl (extraction + runner).
(import doc_test_tests as doc_tests)

(define (main) : i64
  (doc_tests.doc-test-smoke-all))