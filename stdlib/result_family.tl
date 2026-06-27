;# Lightweight generated result module macro for compiler-internal use.
;#
;# Import with `(import "stdlib/result_family.tl")`, then instantiate a
;# concrete module with `(import (result i64 String) as result_i64_string)`.
;# This emits only the enum surface, so hot compiler modules can use generated
;# `Result.Ok` / `Result.Err` without importing the public helper API from
;# `stdlib/result.tl`.
(module stdlib.result_family)

;: Emit a generated recoverable-error result module for success type `T` and
;: error type `E`.
(defmacro (result [T : type] [E : type]) : Module
  (let
    [module-name : Expr
      (expr-var
        (string-append
          (string-append "stdlib.result_family.generated." (type-key T))
          (string-append "." (type-key E))))]
    [result-name : Expr (expr-var "Result")]
    `(begin
      (module ,module-name)
      (defenum ,result-name
        (Ok ,T)
        (Err ,E)))))

(cfg test (import stdlib.test))
(cfg test (import (result i64 String) as result_family_i64_string))

(cfg
  test
  (test
    result_family_direct_variants
    (let
      [hit : result_family_i64_string.Result (result_family_i64_string.Ok 41)]
      [miss : result_family_i64_string.Result
        (result_family_i64_string.Err "no")]
      [expected : String "no"]
      (begin
        (match hit
          [(result_family_i64_string.Ok value)
            (test.assert-i64-eq value 41 "result family ok payload")]
          [(result_family_i64_string.Err _)
            (test.assert-true false "result family expected ok")])
        (match miss
          [(result_family_i64_string.Ok _)
            (test.assert-true false "result family expected err")]
          [(result_family_i64_string.Err message)
            (test.assert-string-eq
              (& message)
              (& expected)
              "result family err payload")])))))