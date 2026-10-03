(import compiler_scoped_stack as scoped_stack)

(defstruct ScopedSelection
  (slots (__tl_dyn-array i64))
  (len i64)
  (top (__tl_dyn-array i64)))

(scoped_stack.compiler-scoped-stack-operations
  i64
  ScopedSelection
  scoped-selection
  push)

(define (main) : i64
  (scoped-selection-empty)
  0)