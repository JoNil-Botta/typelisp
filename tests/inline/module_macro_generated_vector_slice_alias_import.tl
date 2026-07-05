;; module_macro_generated_vector_slice_alias_import.tl - generated module bodies
;; can import generated slice modules through an alias while the slice body
;; imports the matching `(vector T)` module.
(import stdlib.test)
(import stdlib.vector)
(import stdlib.vector_slice as vs)

(defstruct Pair
  (value i64))

(defmacro (slice-user [T : type]) : Module
  (let
    [module-name : Expr
      (expr-var (string-append "generated.slice_alias_user." (type-key T)))]
    `(begin
      (module ,module-name)
      (import (vector ,T) as vec)
      (import (vs.slice ,T) as slice)
      (define (score [first : ,T] [fallback : ,T]) : i64
        (let
          [items : vec.Vec (vec.new)]
          (begin
            (vec.push (&mut items) first)
            (let
              [view : (slice.Slice items) (slice.all-vec (& items))]
              (if (= (slice.len view) 1)
                (begin
                  (slice.get view 0 fallback)
                  42)
                0))))))))

(import (slice-user i64) as user)
(import (slice-user Pair) as pair-user)

(test
  generated-module-body-imports-vector-slice-alias-module-macro-i64
  (test.assert-i64-eq
    (user.score 7 0)
    42
    "generated body imports aliased slice module macro"))

(test
  generated-module-body-imports-vector-slice-alias-module-macro-struct
  (test.assert-i64-eq
    (pair-user.score (Pair 7) (Pair 0))
    42
    "generated body imports aliased slice module macro struct"))