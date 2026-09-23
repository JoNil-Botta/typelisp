;; Runnable native smoke for strict Git object decoding and resolution.
(import git_object_tests)

(define (main) : i64
  (git_object_tests.git-object-self-test))