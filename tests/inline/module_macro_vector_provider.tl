;; module_macro_vector_provider.tl - helper module for generated vector imports.
(module tests.module_macro_vector_provider)

(import "stdlib/vector.tl")

(defmacro (vector-user [T : type]) : Module
  (let
    [module-name : Expr
      (expr-var (string-append "generated.provider_vector_user." (type-key T)))]
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
              0))))
      (export (value score)))))

(export (macro vector-user))