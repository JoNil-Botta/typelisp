(import stdlib.result)
(import stdlib.test)
(import (result i64 String) as result_i64_string)
(import (result i64 String) as result_i64_string_again)
(import (result String i64) as result_string_i64)

(define (result-test-inc [value : i64]) : i64
  (+ value 1))

(define (result-test-duplicate-import-score
  [value : result_i64_string_again.Result]) : i64
  (result_i64_string_again.value-or value 0))

(defmacro (result-test-user [T : type] [E : type]) : Module
  (let
    [module-name : Expr
      (expr-var
        (string-append
          (string-append "stdlib.result.test_user.generated." (type-key T))
          (string-append "." (type-key E))))]
    `(begin
      (module ,module-name)
      (import (result ,T ,E) as local_result)
      (define (value-or [value : local_result.Result] [fallback : ,T]) : ,T
        (match value
          [(local_result.Ok inner) inner]
          [(local_result.Err _) fallback])))))

(import (result-test-user i64 String) as result_i64_string_user)

;; P4/C4.5 author-time canonical instantiations: cover struct and enum element
;; kinds (scalar/String are covered above) so the whole generated result body is
;; typechecked in CI for every representative element kind, before any consumer.
(defstruct ResApiPoint
  (x i64)
  (y i64))

(defenum ResApiTag
  (ResApiTagA i64)
  (ResApiTagB i64))

(import (result ResApiPoint ResApiTag) as result_struct_enum)

(test
  result-macro-struct-and-enum-element-kinds
  (let
    [ok-v : result_struct_enum.Result (result_struct_enum.ok (ResApiPoint 1 2))]
    [err-v : result_struct_enum.Result (result_struct_enum.err (ResApiTagA 5))]
    (begin
      (test.assert-true
        (result_struct_enum.is-ok? (& ok-v))
        "struct/enum result ok predicate")
      (test.assert-true
        (result_struct_enum.is-err? (& err-v))
        "struct/enum result err predicate"))))

(test
  result-macro-i64-string-api
  (let
    [hit : result_i64_string.Result (result_i64_string.ok 41)]
    [miss : result_i64_string.Result (result_i64_string.err "no")]
    (begin
      (test.assert-true
        (result_i64_string.is-ok? (& hit))
        "result ok predicate")
      (test.assert-true
        (result_i64_string.is-err? (& miss))
        "result err predicate")
      (test.assert-i64-eq
        (result_i64_string.value-or hit 0)
        41
        "result value-or returns ok payload")
      (test.assert-i64-eq
        (result_i64_string.value-or miss 7)
        7
        "result value-or returns fallback"))))

(test
  result-macro-map-and-duplicate-import
  (let
    [mapped : result_i64_string.Result
      (result_i64_string.map (result_i64_string.ok 41) result-test-inc)]
    [mapped-err : result_i64_string.Result
      (result_i64_string.map (result_i64_string.err "bad") result-test-inc)]
    (begin
      (test.assert-i64-eq
        (result_i64_string.value-or mapped 0)
        42
        "result map transforms ok payload")
      (test.assert-i64-eq
        (result_i64_string.value-or mapped-err 5)
        5
        "result map preserves err shape")
      (test.assert-i64-eq
        (result-test-duplicate-import-score (result_i64_string.ok 9))
        9
        "duplicate result imports share the same generated type")
      (test.assert-i64-eq
        (result_i64_string_user.value-or (result_i64_string.ok 12) 0)
        12
        "generated module result imports share the same generated type"))))

(test
  result-macro-string-i64-api
  (let
    [hit : result_string_i64.Result (result_string_i64.ok "bee")]
    [miss : result_string_i64.Result (result_string_i64.err 4)]
    [expected-hit : String "bee"]
    [expected-miss : String "fallback"]
    (begin
      (let
        [actual-hit : String (result_string_i64.value-or hit "bad")]
        (test.assert-string-eq
          (& actual-hit)
          (& expected-hit)
          "string result value-or returns ok payload"))
      (let
        [actual-miss : String (result_string_i64.value-or miss "fallback")]
        (test.assert-string-eq
          (& actual-miss)
          (& expected-miss)
          "string result value-or returns fallback")))))