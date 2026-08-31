;; Runnable smoke for the bounded Git delta decoder/resolver fixtures.
(import git_delta_tests)

(define (main) : i64
  (git_delta_tests.git-delta-self-test))