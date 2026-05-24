;; doc_test_smoke.tl - Runnable smoke for doc_test.tl (#722 extraction + #724

;; runner).

(import "doc_test.tl")

(define (main) : i64
  (doc-test-smoke-all))