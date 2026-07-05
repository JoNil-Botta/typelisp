;; module_macro_generated_body_imports_param_vector_module.tl - generated module
;; bodies can import stdlib.vector locally and then instantiate `(vector T)`
;; using the enclosing module macro's type parameter.
(import stdlib.test)

(defstruct Pair
  (value i64))

(defmacro (vector-user [T : type]) : Module
  (let
    [module-name : Expr
      (expr-var
        (string-append "generated.body_param_vector_user." (type-key T)))]
    `(begin
      (module ,module-name)
      (import stdlib.vector)
      (import (vector T) as vec)
      (define (score [first : ,T] [fallback : ,T]) : i64
        (let
          [items : vec.Vec (vec.new)]
          (begin
            (vec.push (&mut items) first)
            (if (= (vec.len (& items)) 1)
              (begin
                (vec.get (& items) 0 fallback)
                42)
              0)))))))

(import (vector-user i64) as user)
(import (vector-user Pair) as pair-user)

(test
  generated-module-body-imports-param-vector-module-macro-i64
  (test.assert-i64-eq
    (user.score 7 0)
    42
    "generated module body imports param vector macro i64"))

(test
  generated-module-body-imports-param-vector-module-macro-struct
  (test.assert-i64-eq
    (pair-user.score (Pair 7) (Pair 0))
    42
    "generated module body imports param vector macro struct"))