;; module_macro_generated_stdlib_vector_bare_import.tl - generated module bodies
;; can use the bare `(import (vector T))` module-macro import surface.
(import stdlib.test)
(import stdlib.vector)

(defstruct Pair
  (value i64))

(defmacro (vector-user [T : type]) : Module
  (let
    [module-name : Expr
      (expr-var
        (string-append "generated.stdlib_vector_bare_user." (type-key T)))]
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

(import (vector-user i64) as user)
(import (vector-user String) as string-user)
(import (vector-user Pair) as pair-user)

(test
  generated-module-body-bare-imports-stdlib-vector-module-macro
  (test.assert-i64-eq
    (user.score 7 0)
    42
    "generated module bare-imported stdlib vector macro"))

(test
  generated-module-body-bare-imports-stdlib-string-vector-module-macro
  (test.assert-i64-eq
    (string-user.score "alpha" "fallback")
    42
    "generated module bare-imported stdlib string vector macro"))

(test
  generated-module-body-bare-imports-stdlib-struct-vector-module-macro
  (test.assert-i64-eq
    (pair-user.score (Pair 7) (Pair 0))
    42
    "generated module bare-imported stdlib struct vector macro"))
