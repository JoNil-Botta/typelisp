;; Small ordinary inline input for the same-process test-entry resource guard.
(import stdlib.test)

(test
  batch-entry-leaf
  (test.assert-i64-eq (+ 20 22) 42 "batch entry executes its test"))