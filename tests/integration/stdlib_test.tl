;; tests/integration/stdlib_test.tl - Integration test for stdlib/test.tl
;; Test harnesses stage stdlib/test.tl under this import name.
;;
;; Expected stdout: empty
;; Exit code: 42
(import stdlib.test)
(import stdlib.io)
(import stdlib.string)

(define (assert-owned-string-eq
  [actual : String]
  [expected : String]
  [message : String]) : unit
  (test.assert-string-eq (& actual) (& expected) message))

(define (run-failure-case [name : (& name str)]) : i64
  (cond
    [(string.eq name "bool")
      (begin
        (test.assert-bool-eq true false "bool mismatch")
        1)]
    [(string.eq name "i64")
      (begin
        (test.assert-i64-eq 26 27 "score mismatch")
        1)]
    [(string.eq name "i32")
      (begin
        (test.assert-i32-eq (cast -3 : i32) (cast 4 : i32) "offset mismatch")
        1)]
    [(string.eq name "f64")
      (begin
        (test.assert-f64-eq 1.25 2.5 "ratio mismatch")
        1)]
    [(string.eq name "char")
      (begin
        (test.assert-char-eq 'x' 'y' "mark mismatch")
        1)]
    [(string.eq name "string")
      (begin
        (assert-owned-string-eq "left" "right" "name mismatch")
        1)]
    [else 2]))

(define (main) : i64
  (if (> (io.arg-count) 1)
    (run-failure-case (io.arg 1))
    (begin
      (test.assert-true true "assert-true should pass")
      (test.assert-false false "assert-false should pass")
      (test.assert-bool-eq true true "bool equality should pass")
      (test.assert-i64-eq 42 42 "i64 equality should pass")
      (test.assert-i32-eq
        (cast 7 : i32)
        (cast 7 : i32)
        "i32 equality should pass")
      (test.assert-f64-eq 1.5 1.5 "f64 equality should pass")
      (test.assert-char-eq 'A' 'A' "char equality should pass")
      (assert-owned-string-eq "hello" "hello" "string equality should pass")
      42)))