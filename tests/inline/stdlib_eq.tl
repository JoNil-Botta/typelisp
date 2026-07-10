;; stdlib_eq.tl - generated scalar equality modules (#3868).
(import stdlib.test)
(import stdlib.eq)
(import (eq.eq i64) as i64-eq)
(import (eq.eq i64) as i64-eq-again)
(import (eq.eq u8) as u8-eq)
(import (eq.eq (type unit)) as unit-eq)
(import (eq.eq String) as string-eq)

(test
  stdlib-eq-generated-scalar-modules
  (begin
    (test.assert-true (i64-eq.eq 42 42) "i64 equality succeeds")
    (test.assert-false (i64-eq.eq? 42 7) "i64 equality detects mismatch")
    (test.assert-true (i64-eq-again.eq? 9 9) "duplicate i64 import succeeds")
    (test.assert-true (u8-eq.eq 7 7) "u8 equality succeeds")
    (test.assert-true (unit-eq.eq unit unit) "unit equality succeeds")
    (test.assert-true (string-eq.eq "same" "same") "string equality succeeds")
    (test.assert-false
      (string-eq.eq? "left" "right")
      "string equality detects mismatch")))