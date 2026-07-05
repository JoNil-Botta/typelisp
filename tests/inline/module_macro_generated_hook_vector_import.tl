;; module_macro_generated_hook_vector_import.tl - generated module bodies can
;; import stdlib `(vector T)` through a module hook macro value.
(import stdlib.test)
(import stdlib.comptime)
(import stdlib.vector)

(defstruct Pair
  (value i64))

(defmacro (vector-user [factory : Module] [T : type]) : Module
  (let
    [module-name : Expr
      (comptime.expr-var
        (comptime.string-append "generated.hook_vector_user." (type-key T)))]
    [vector-macro : Expr (module-hook factory "vector")]
    `(begin
      (module ,module-name)
      (import (,vector-macro ,T) as vec)
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

(import (vector-user vector i64) as user)
(import (vector-user vector Pair) as pair-user)

(test
  generated-module-body-imports-hooked-vector-module-macro-i64
  (test.assert-i64-eq
    (user.score 7 0)
    42
    "generated module hooked vector import i64"))

(test
  generated-module-body-imports-hooked-vector-module-macro-struct
  (test.assert-i64-eq
    (pair-user.score (Pair 7) (Pair 0))
    42
    "generated module hooked vector import struct"))