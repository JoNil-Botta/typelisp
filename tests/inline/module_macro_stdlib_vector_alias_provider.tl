;; module_macro_stdlib_vector_alias_provider.tl - helper module for exported
;; module macros whose generated bodies use the provider's dotted vector import.
(module tests.module_macro_stdlib_vector_alias_provider)

(import stdlib.vector)

(defmacro (vector-user [T : type]) : Module
  (let
    [module-name : Expr
      (expr-var
        (string-append
          "generated.provider_stdlib_vector_alias_user."
          (type-key T)))]
    `(begin
      (module ,module-name)
      (import (vector ,T) as vec)
      (define (score [first : ,T] [fallback : ,T]) : i64
        (let
          [items : vec.Vec (vec.new)]
          (begin
            (vec.push (&mut items) first)
            (if (if (= (vec.len (& items)) 1)
              (not (vec.is-empty? (& items)))
              false)
              (begin
                (vec.get (& items) 0 fallback)
                42)
              0)))))))