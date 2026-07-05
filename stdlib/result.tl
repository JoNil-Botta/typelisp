;# Generic recoverable-error result module macro.
;#
;# Import with `(import stdlib.result)`, then instantiate a concrete module
;# with `(import (result i64 String) as result_i64_string)`.
(module stdlib.result)

;: Emit a generated recoverable-error result module for success type `T` and
;: error type `E`.
(defmacro (result [T : type] [E : type]) : Module
  (let
    [module-name : Expr
      (expr-var
        (string-append
          (string-append "stdlib.result.generated." (type-key T))
          (string-append "." (type-key E))))]
    [result-name : Expr (expr-var "Result")]
    [ok-name : Expr (expr-var "Ok")]
    [err-name : Expr (expr-var "Err")]
    `(begin
      (module ,module-name)
      (defenum ,result-name
        (Ok ,T)
        (Err ,E))
      (define (ok [value : ,T]) : ,result-name
        (,ok-name value))
      (define (err [error : ,E]) : ,result-name
        (,err-name error))
      (define (is-ok? [value : (& value ,result-name)]) : bool
        (match value
          [(Ok _) true]
          [(Err _) false]))
      (define (is-err? [value : (& value ,result-name)]) : bool
        (match value
          [(Ok _) false]
          [(Err _) true]))
      (define (value-or [value : ,result-name] [fallback : ,T]) : ,T
        (match value
          [(Ok inner) inner]
          [(Err _) fallback]))
      (define (map [value : ,result-name] [mapper : (-> ,T ,T)]) : ,result-name
        (match value
          [(Ok inner) (ok (mapper inner))]
          [(Err error) (err error)])))))

(cfg test (import stdlib.test))
(cfg test (import (result i64 String) as result_i64_string))
(cfg test (import (result i64 String) as result_i64_string_again))
(cfg test (import (result String i64) as result_string_i64))

(cfg
  test
  (define (result-test-inc [value : i64]) : i64
    (+ value 1)))

(cfg
  test
  (define (result-test-duplicate-import-score
    [value : result_i64_string_again.Result]) : i64
    (result_i64_string_again.value-or value 0)))

(cfg
  test
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
            [(local_result.Err _) fallback]))))))

(cfg test (import (result-test-user i64 String) as result_i64_string_user))

;; P4/C4.5 author-time canonical instantiations: cover struct and enum element
;; kinds (scalar/String are covered above) so the whole generated result body is
;; typechecked in CI for every representative element kind, before any consumer.
(cfg
  test
  (defstruct ResApiPoint
    (x i64)
    (y i64)))

(cfg
  test
  (defenum ResApiTag
    (ResApiTagA i64)
    (ResApiTagB i64)))

(cfg test (import (result ResApiPoint ResApiTag) as result_struct_enum))

(cfg
  test
  (test
    result-macro-struct-and-enum-element-kinds
    (let
      [ok-v : result_struct_enum.Result
        (result_struct_enum.ok (ResApiPoint 1 2))]
      [err-v : result_struct_enum.Result
        (result_struct_enum.err (ResApiTagA 5))]
      (begin
        (test.assert-true
          (result_struct_enum.is-ok? (& ok-v))
          "struct/enum result ok predicate")
        (test.assert-true
          (result_struct_enum.is-err? (& err-v))
          "struct/enum result err predicate")))))

(cfg
  test
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
          "result value-or returns fallback")))))

(cfg
  test
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
          "generated module result imports share the same generated type")))))

(cfg
  test
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
            "string result value-or returns fallback"))))))