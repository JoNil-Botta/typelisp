;; module_macro_stdlib_vector_bare_provider.tl - helper module for exported
;; module macros whose generated bodies flat-import generated stdlib vectors.
(module tests.module_macro_stdlib_vector_bare_provider)

(import stdlib.vector)

(defmacro (vector-user [T : type]) : Module
  (let
    [module-name : Expr
      (expr-var
        (string-append
          "generated.provider_stdlib_vector_bare_user."
          (type-key T)))]
    `(begin
      (module ,module-name)
      (import (vector ,T))
      (define (score [first : ,T] [fallback : ,T]) : i64
        (let
          [items : Vec (new)]
          (begin
            (push (&mut items) first)
            (if (if (= (len (& items)) 1)
              (not (is-empty? (& items)))
              false)
              (begin
                (get (& items) 0 fallback)
                42)
              0)))))))
