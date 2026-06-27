;; test_cli_stdlib_env_smoke.tl - Runnable smoke for test CLI stdlib/env fixture routing.
(import "../test_cli_core.tl")

(test
  test-cli-stdlib-env-fixture-is-target-aware
  (unless
    (tltest-stdlib-env-fixture-self-test?)
    (panic "test CLI stdlib/env fixture routing mismatch")))