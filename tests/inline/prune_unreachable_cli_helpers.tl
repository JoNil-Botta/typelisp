(import "stdlib/test.tl")
(import "unreachable_cli_helper_lib.tl")

(test
  imported-unused-cli-helper-is-pruned
  (assert-i64-eq
    (reachable-helper 41)
    42
    "inline harness should not link unused imported CLI helpers"))