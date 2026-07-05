;; tests/integration/stdlib_test.tl - Integration test for stdlib/test.tl
;; Test harnesses stage stdlib/test.tl under this import name.
;;
;; Expected stdout: empty
;; Exit code: 42
(import stdlib.test)

(define (assert-owned-string-eq
  [actual : String]
  [expected : String]
  [message : String]) : unit
  (test.assert-string-eq (& actual) (& expected) message))

(define (main) : i64
  (begin
    (test.assert-true true "assert-true should pass")
    (test.assert-false false "assert-false should pass")
    (test.assert-bool-eq true true "bool equality should pass")
    (test.assert-i64-eq 42 42 "i64 equality should pass")
    (test.assert-i32-eq (cast 7 : i32) (cast 7 : i32) "i32 equality should pass")
    (test.assert-f64-eq 1.5 1.5 "f64 equality should pass")
    (test.assert-char-eq 'A' 'A' "char equality should pass")
    (assert-owned-string-eq "hello" "hello" "string equality should pass")
    42))
