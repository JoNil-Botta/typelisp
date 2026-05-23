;; tests/integration/stdlib_test.tl - Integration test for stdlib/test.tl
;;
;; Exit code: 42

(import "stdlib/test.tl")

(define (main) : i64
  (begin
    (assert-true true "assert-true failed")
    (assert-false false "assert-false failed")
    (assert-bool-eq (= 1 1) true "assert-bool-eq failed")
    (assert-i64-eq (+ 40 2) 42 "assert-i64-eq failed")
    (assert-char-eq #A' #A' "assert-char-eq failed")
    (assert-string-eq (string-append "ty" "pelisp") "typelisp" "assert-string-eq failed")
    42))
