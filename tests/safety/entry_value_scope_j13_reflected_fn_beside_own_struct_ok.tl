;; #9687: a reflected entry function beside a same-named struct in the generated module.
(import stdlib.comptime)
(import entry_value_scope_j13_reflected_fn_beside_own_struct_ok_lib)

(defstruct Foo
  (x i64))

(define (make) : i64
  42)

(defmacro (gen [T : type]) : Module
  `(begin
    (module generated.q)
    (import entry_value_scope_j13_reflected_fn_beside_own_struct_ok_lib.*)
    (defstruct make
      (y i64))
    (define (call-it) : i64
      (rc0-make ,T))))

(import (gen Foo) as g)

(define (main) : i64
  (g.call-it))