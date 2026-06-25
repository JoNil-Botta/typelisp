;; test_cli_spawn_error_smoke.tl - Runnable smoke for test CLI spawn diagnostics.
(import "../test_cli_core.tl")

(test
  test-cli-spawn-error-preserves-artifacts
  (unless
    (tltest-run-executable-error-message-self-test?)
    (panic "test CLI spawn error diagnostic did not preserve artifacts")))