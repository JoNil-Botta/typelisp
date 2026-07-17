;; module_macro_generated_chained_vector_import.tl - generated module bodies can
;; pass captured tuple type operands through another module macro that imports
;; stdlib `(vector T)`.
(import stdlib.test)
(import stdlib.vector)

(defmacro (tuple-vector-box [T : type]) : Module
  (let
    [module-name : Expr
      (expr-var
        (string-append "generated.chained_tuple_vector_box." (type-key T)))]
    `(begin
      (module ,module-name)
      (import (vector T) as vec)
      (define (score [first : ,T] [fallback : ,T]) : i64
        (let
          [items : vec.Vec (vec.new)]
          (begin
            (vec.push! items first)
            (if (= (vec.len (& items)) 1)
              (begin
                (vec.get (& items) 0 fallback)
                42)
              0)))))))

(defmacro (tuple-vector-user [T : type]) : Module
  (let
    [module-name : Expr
      (expr-var
        (string-append "generated.chained_tuple_vector_user." (type-key T)))]
    `(begin
      (module ,module-name)
      (import (tuple-vector-box T) as box)
      (define (score [first : ,T] [fallback : ,T]) : i64
        (box.score first fallback)))))

(import (tuple-vector-user (Tuple i64 i64)) as user)

(test
  generated-module-body-chained-imports-tuple-vector-module-macro
  (test.assert-i64-eq
    (user.score (tuple 7 8) (tuple 0 0))
    42
    "generated module chained tuple vector import"))