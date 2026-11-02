(import program_lifetime_visibility_defs as defs)

(defstruct T
  (:lifetimes r)
  (value (defs.S r)))

;; The reserved lifetime needs no binding, including through imported fields.
(define (probe [leaf : (T program)]) : i64
  (let
    [x0 leaf]
    0))

(define (main) : i64
  0)