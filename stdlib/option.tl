;# Generic absence-only option module macro.
;#
;# Import with `(import stdlib.option)`, then instantiate a concrete module
;# with `(import (option i64) as option_i64)` or
;# `(import (option String) as option_string)`.
(module stdlib.option)

(import stdlib.comptime)

;: Emit a generated absence-only option module for payload type `T`.
(defmacro (option [T : type]) : Module
  (let
    [module-name : comptime.Expr
      (comptime.expr-var
        (comptime.string-append "stdlib.option.generated." (type-key T)))]
    [option-name : comptime.Expr (comptime.expr-var "Option")]
    [none-name : comptime.Expr (comptime.expr-var "Option.None")]
    [some-name : comptime.Expr (comptime.expr-var "Option.Some")]
    `(begin
      (module ,module-name)
      (defenum ,option-name
        (None)
        (Some ,T))
      (define (some [value : ,T]) : ,option-name
        (,some-name value))
      (define (none) : ,option-name
        (,none-name))
      (define (is-some? [value : (& value ,option-name)]) : bool
        (match value
          [(Some _) true]
          [None false]))
      (define (is-none? [value : (& value ,option-name)]) : bool
        (match value
          [(Some _) false]
          [None true]))
      (define (value-or [value : ,option-name] [fallback : ,T]) : ,T
        (match value
          [(Some inner) inner]
          [None fallback]))
      (define (map [value : ,option-name] [mapper : (-> ,T ,T)]) : ,option-name
        (match value
          [(Some inner) (some (mapper inner))]
          [None (none)])))))

(cfg test (import stdlib.test))
(cfg test (import (option i64) as option_i64))
(cfg test (import (option i64) as option_i64_again))
(cfg test (import (option String) as option_string))

(cfg
  test
  (define (option-test-inc [value : i64]) : i64
    (+ value 1)))

(cfg
  test
  (define (option-test-duplicate-import-score [value : option_i64_again.Option]) : i64
    (option_i64_again.value-or value 0)))

(cfg
  test
  (defmacro (option-test-user [T : type]) : Module
    (let
      [module-name : comptime.Expr
        (comptime.expr-var
          (comptime.string-append
            "stdlib.option.test_user.generated."
            (type-key T)))]
      `(begin
        (module ,module-name)
        (import (option ,T) as local_option)
        (define (value-or [value : local_option.Option] [fallback : ,T]) : ,T
          (local_option.value-or value fallback))))))

(cfg test (import (option-test-user i64) as option_i64_user))

(cfg
  test
  (test
    option-macro-i64-api
    (let
      [hit : option_i64.Option (option_i64.some 41)]
      [miss : option_i64.Option (option_i64.none)]
      (begin
        (test.assert-true
          (option_i64.is-some? (& hit))
          "i64 option some predicate")
        (test.assert-true
          (option_i64.is-none? (& miss))
          "i64 option none predicate")
        (test.assert-i64-eq
          (option_i64.value-or hit 0)
          41
          "i64 option value-or returns payload")
        (test.assert-i64-eq
          (option_i64.value-or miss 7)
          7
          "i64 option value-or returns fallback")))))

(cfg
  test
  (test
    option-macro-map-and-duplicate-import
    (let
      [mapped : option_i64.Option
        (option_i64.map (option_i64.some 41) option-test-inc)]
      (begin
        (test.assert-i64-eq
          (option_i64.value-or mapped 0)
          42
          "i64 option map transforms payload")
        (test.assert-i64-eq
          (option-test-duplicate-import-score (option_i64.some 9))
          9
          "duplicate option imports share the same generated type")
        (test.assert-i64-eq
          (option_i64_user.value-or (option_i64.some 12) 0)
          12
          "generated module option imports share the same generated type")))))

(cfg
  test
  (test
    option-macro-string-api
    (let
      [hit : option_string.Option (option_string.some "bee")]
      [miss : option_string.Option (option_string.none)]
      [expected-hit : String "bee"]
      [expected-miss : String "fallback"]
      (begin
        (let
          [actual-hit : String (option_string.value-or hit "bad")]
          (test.assert-string-eq
            (& actual-hit)
            (& expected-hit)
            "string option value-or returns payload"))
        (let
          [actual-miss : String (option_string.value-or miss "fallback")]
          (test.assert-string-eq
            (& actual-miss)
            (& expected-miss)
            "string option value-or returns fallback"))))))