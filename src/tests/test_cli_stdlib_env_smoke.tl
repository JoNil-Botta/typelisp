;; test_cli_stdlib_env_smoke.tl - Runnable smoke for test CLI stdlib/env fixture routing.
(import test_cli_core)
(import stdlib.io)

(test
  test-cli-stdlib-env-fixture-is-target-aware
  (unless
    (test_cli_core.tltest-stdlib-env-fixture-self-test?)
    (io.panic "test CLI stdlib/env fixture routing mismatch")))