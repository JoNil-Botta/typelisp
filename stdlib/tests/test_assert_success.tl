(import "stdlib/test.tl")

(define (assert-owned-string-eq
  [actual : String]
  [expected : String]
  [message : String]) : unit
  (assert-string-eq (& actual) (& expected) message))

(define (main) : i64
  (begin
    (assert-true true "true should pass")
    (assert-false false "false should pass")
    (assert-bool-eq true true "bool equality should pass")
    (assert-i64-eq 42 42 "i64 equality should pass")
    (assert-i32-eq (cast 7 : i32) (cast 7 : i32) "i32 equality should pass")
    (assert-f64-eq 1.5 1.5 "f64 equality should pass")
    (assert-char-eq #A' #A' "char equality should pass")
    (assert-owned-string-eq "hello" "hello" "string equality should pass")
    42))