;; #9687: an entry struct constructor reached by reflection from a generated module.
(import stdlib.comptime)
(import entry_value_scope_j8_reflected_struct_ctor_ok_lib)

(defstruct Foo
  (x i64))

(defmacro (gen [T : type]) : Module
  `(begin
    (module generated.q)
    (import entry_value_scope_j8_reflected_struct_ctor_ok_lib.*)
    (define (mk) : ,T
      (rv ,T))
    (define (call-it) : i64
      (let
        [f (mk)]
        f.x))))

(import (gen Foo) as g)

(define (main) : i64
  (g.call-it))