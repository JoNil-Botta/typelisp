(import stdlib.test)
(import unreachable_cli_helper_lib as helper)

(test
  imported-unused-cli-helper-is-pruned
  (test.assert-i64-eq
    (helper.reachable-helper 41)
    42
    "inline harness should not link unused imported CLI helpers"))
