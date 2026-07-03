;; test_cli_nested_generated_result_helper_smoke.tl - Inline harness smoke for nested generated result imports.
(import "../test_cli_core.tl")

(test
  test-cli-inline-harness-nested-generated-result-helper
  (if (tltest-nested-generated-result-helper-self-test?)
    unit
    (panic "test CLI nested generated result helper import mismatch")))