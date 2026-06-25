;; test_cli_nested_module_macro_vector_smoke.tl - Inline harness smoke for nested generated vector imports.
(import "../test_cli_core.tl")

(test
  test-cli-inline-harness-nested-module-macro-vector-import
  (if (tltest-nested-module-macro-vector-self-test?)
    unit
    (panic "test CLI nested module macro vector import mismatch")))