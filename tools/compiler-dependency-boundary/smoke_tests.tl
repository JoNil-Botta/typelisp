(import smoke)
(import boundary_core as boundary)
(import stdlib.json)
(import stdlib.test)

(test
  fixture-policy-portable-paths
  (let
    [windows : json.JsonSeq
      (boundary.json-array
        (smoke.policy-row "target\\fixtures\\root.tl" "core"))]
    [linux : json.JsonSeq
      (boundary.json-array (smoke.policy-row "target/fixtures/root.tl" "core"))]
    (test.assert-owned-string-eq
      (smoke.text-item (& windows) 0)
      "target/fixtures/root.tl"
      "Windows fixture paths use the portable policy spelling")
    (test.assert-owned-string-eq
      (smoke.text-item (& linux) 0)
      "target/fixtures/root.tl"
      "Linux fixture paths retain the portable policy spelling")))