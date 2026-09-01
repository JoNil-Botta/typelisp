;; Runnable smoke for the pure Git-over-SSH remote/request boundary.
(import git_ssh_remote_tests)

(define (main) : i64
  (git_ssh_remote_tests.git-ssh-remote-self-test))