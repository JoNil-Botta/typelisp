(import "comptime_module_value_reflection_provider.tl" module reflection.signature.provider as provider)
(import stdlib.comptime)

(defmacro (generated-provider) : Module
  `(begin
    (module generated.reflection.signature)
    (define answer : i64
      42)
    (define (make [value : i64]) : bool
      (> value 0))))

(import (generated-provider) as generated)

(defmacro (signature-score [target : Module] [expected : type]) : i64
  (let
    [module : String (comptime.module-name target)]
    [present : bool (comptime.module-value? module "make")]
    [signature-ok : bool
      (if present
        (= (comptime.module-value-type module "make") expected)
        false)]
    (comptime.expr-int
      (if present
        (if signature-ok
          14
          0)
        0))))

(defmacro (stdlib-signature-score [target : Module] [expected : type]) : i64
  (let
    [module : String (comptime.module-name target)]
    [present : bool (comptime.module-value? module "expr-bool")]
    [signature-ok : bool
      (if present
        (= (comptime.module-value-type module "expr-bool") expected)
        false)]
    (comptime.expr-int
      (if present
        (if signature-ok
          14
          0)
        0))))

(defmacro (reference-protocol-score [source : Expr] [expected-return : type]) : i64
  (let
    [source-type : Expr (comptime.expr-type source)]
    [source-kind : String (type-kind source-type)]
    [referent : Expr (comptime.reference-element-type source-type)]
    [module : String (type-nominal-module referent)]
    [function-name : String
      (if (__tl_string_eq source-kind "ref")
        "observe"
        "update")]
    [present : bool (comptime.module-value? module function-name)]
    [signature-ok : bool
      (if present
        (let
          [signature : Expr (comptime.module-value-type module function-name)]
          [parameter : Expr (function-param-type signature 0)]
          (if (= (function-param-count signature) 1)
            (if (__tl_string_eq (type-kind parameter) source-kind)
              (if (= (comptime.reference-element-type parameter) referent)
                (= (function-return-type signature) expected-return)
                false)
              false)
            false))
        false)]
    (comptime.expr-int
      (if signature-ok
        (if (__tl_string_eq source-kind "ref")
          20
          22)
        0))))

(define (shared-protocol-score [source : (& caller provider.Token)]) : i64
  (reference-protocol-score source i64))

(define (mutable-protocol-score [source : (&mut caller provider.Token)]) : i64
  (reference-protocol-score source i64))

(define (main) : i64
  (let
    [signature-total : i64
      (+
        (signature-score provider (-> i64 bool))
        (+
          (signature-score generated (-> i64 bool))
          (stdlib-signature-score comptime (-> bool Expr))))]
    [token : provider.Token (provider.Token 42)]
    [protocol-total : i64
      (+
        (shared-protocol-score (& token))
        (mutable-protocol-score (&mut token)))]
    (if (= protocol-total 42)
      signature-total
      0)))