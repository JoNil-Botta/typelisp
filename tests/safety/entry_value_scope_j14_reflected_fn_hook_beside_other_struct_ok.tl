;; #9687: a reflected entry function through module-hook beside a same-named struct.
(import entry_value_scope_j14_reflected_fn_hook_beside_other_struct_ok_dep)
(import stdlib.comptime)
(import entry_value_scope_j14_reflected_fn_hook_beside_other_struct_ok_lib)

(defstruct Foo
  (x i64))

(define (make [a : i64]) : i64
  (+ a 1))

(defmacro (gen [T : type]) : Module
  `(begin
    (module generated.q)
    (import entry_value_scope_j14_reflected_fn_hook_beside_other_struct_ok_lib.*)
    (define (call-it) : i64
      (hk-make ,T))))

(import (gen Foo) as g)

(define (main) : i64
  (g.call-it))