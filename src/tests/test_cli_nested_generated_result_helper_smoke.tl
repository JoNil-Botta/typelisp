;; test_cli_nested_generated_result_helper_smoke.tl - Inline harness smoke for nested generated result imports.
(import test_cli_core)
(import stdlib.io)

(test
  test-cli-inline-harness-nested-generated-result-helper
  (if (test_cli_core.tltest-nested-generated-result-helper-self-test?)
    unit
    (io.panic "test CLI nested generated result helper import mismatch")))