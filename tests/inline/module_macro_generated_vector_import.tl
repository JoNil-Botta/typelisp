;; module_macro_generated_vector_import.tl - generated module bodies can import
;; generated vector modules through an inner module-macro import.
(import "stdlib/test.tl")
(import "stdlib/vector.tl")

(defmacro (vector-user [T : type]) : Module
  (let
    [module-name : Expr
      (expr-var (string-append "generated.vector_user." (type-key T)))]
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

(import (vector-user i64) as user)
(import (vector-user String) as string-user)

(test
  generated-module-body-imports-vector-module-macro
  (assert-i64-eq (user.score 7 0) 42 "generated module imported vector macro"))

(test
  generated-module-body-imports-string-vector-module-macro
  (assert-i64-eq
    (string-user.score "alpha" "fallback")
    42
    "generated module imported string vector macro"))