(import fixture_policy)
(import stdlib.json)
(import stdlib.test)

(test
  fixture-policy-portable-paths
  (test.assert-owned-string-eq
    (json.stringify (fixture_policy.row "target\\fixtures\\root.tl" "core"))
    "[\"target/fixtures/root.tl\",\"core\",\"Explicit test classification.\"]"
    "Windows fixture paths use the portable policy spelling")
  (test.assert-owned-string-eq
    (json.stringify (fixture_policy.row "target/fixtures/root.tl" "core"))
    "[\"target/fixtures/root.tl\",\"core\",\"Explicit test classification.\"]"
    "Linux fixture paths retain the portable policy spelling"))