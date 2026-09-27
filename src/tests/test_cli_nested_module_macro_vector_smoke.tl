;; test_cli_nested_module_macro_vector_smoke.tl - Inline harness smoke for nested generated vector imports.
(import test_cli_core_tests as tltest_tests)
(import stdlib.io)

(test
  test-cli-inline-harness-nested-module-macro-vector-import
  (if (tltest_tests.tltest-nested-module-macro-vector-self-test?)
    unit
    (io.panic "test CLI nested module macro vector import mismatch")))