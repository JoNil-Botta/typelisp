;; test_cli_spawn_error_smoke.tl - Runnable smoke for test CLI spawn diagnostics.
(import test_cli_core_tests as tltest_tests)
(import stdlib.io)

(test
  test-cli-spawn-error-preserves-artifacts
  (unless
    (tltest_tests.tltest-run-executable-error-message-self-test?)
    (io.panic "test CLI spawn error diagnostic did not preserve artifacts")))