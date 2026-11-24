;; Function values are not cloneable in a later generated identity.
(import stdlib.clone)

(defmacro (uncloneable-clone [T : type (:kind i64 function)]) : Module
  (let
    [module-name : Expr
      (expr-var (string-append "generated.uncloneable_clone." (type-key T)))]
    `(begin
      (module ,module-name)
      (import stdlib.clone)
      (define (copy [x : ,T]) : ,T
        (stdlib.clone.deep x)))))

(import (uncloneable-clone i64) as clone_i64)
(import (uncloneable-clone (-> i64 i64)) as clone_function)

(define (main) : i64
  42)