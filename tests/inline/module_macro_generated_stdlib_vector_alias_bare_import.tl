;; module_macro_generated_stdlib_vector_alias_bare_import.tl - dotted imports
;; expose their self-named module macro for bare `(import (vector T) ...)` calls.
(import "stdlib/test.tl")
(import stdlib.vector)

(defstruct Pair
  (value i64))

(import (vector i64) as direct)

(defmacro (vector-user [T : type]) : Module
  (let
    [module-name : Expr
      (expr-var
        (string-append "generated.stdlib_vector_alias_user." (type-key T)))]
    `(begin
      (module ,module-name)
      (import stdlib.vector)
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

(import (vector-user i64) as user)
(import (vector-user String) as string-user)
(import (vector-user Pair) as pair-user)

(test
  dotted-stdlib-vector-import-exposes-bare-vector-module-macro
  (let
    [items : direct.Vec (direct.new)]
    (assert-i64-eq (direct.len (& items)) 0 "dotted stdlib vector bare import")))

(test
  generated-module-body-imports-dotted-stdlib-vector-then-bare-vector
  (assert-i64-eq
    (user.score 7 0)
    42
    "generated body dotted stdlib vector bare import"))

(test
  generated-module-body-imports-dotted-stdlib-vector-string
  (assert-i64-eq
    (string-user.score "alpha" "fallback")
    42
    "generated body dotted stdlib vector bare import string"))

(test
  generated-module-body-imports-dotted-stdlib-vector-struct
  (assert-i64-eq
    (pair-user.score (Pair 7) (Pair 0))
    42
    "generated body dotted stdlib vector bare import struct"))