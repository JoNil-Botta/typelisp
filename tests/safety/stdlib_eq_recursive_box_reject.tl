;: Generated equality stops at a boxed recursive nominal instead of expanding forever.
(import stdlib.eq)

(defstruct EqRecursiveNode
  (next (Box EqRecursiveNode)))

(import (eq.eq EqRecursiveNode) as recursive-node-eq)

(define (main) : i64
  42)