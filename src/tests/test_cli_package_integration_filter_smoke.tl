;; test_cli_package_integration_filter_smoke.tl - Runnable smoke for package integration filtering.
(import test_cli_core)
(import stdlib.io)

(test
  test-cli-package-integration-skips-diagnostics-fixtures
  (if (test_cli_core.tltest-package-integration-filter-self-test?)
    unit
    (io.panic "test CLI package integration filter mismatch")))