;; #9687: a struct constructor, seen from an imported module.
(import entry_value_scope_p04_structctor_ns)

(defstruct Foo
  (x i64))

(define (main) : i64
  (entry_value_scope_p04_structctor_ns.n-struct))