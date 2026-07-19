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

(define (main) : i64
  (+
    (signature-score provider (-> i64 bool))
    (+
      (signature-score generated (-> i64 bool))
      (stdlib-signature-score comptime (-> bool Expr)))))