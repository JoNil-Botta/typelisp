;; test_cli_package_integration_filter_smoke.tl - Runnable smoke for package integration filtering.
(import "../test_cli_core.tl")

(test
  test-cli-package-integration-skips-diagnostics-fixtures
  (if (tltest-package-integration-filter-self-test?)
    unit
    (panic "test CLI package integration filter mismatch")))