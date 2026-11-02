(import program_lifetime_visibility_defs as defs)

(defstruct T
  (:lifetimes r)
  (value (defs.S r)))

;; A local value with the same spelling cannot affect lifetime visibility.
(define (probe [leaf : (T program)]) : i64
  (let
    [program : i64 0]
    [x0 leaf]
    0))

(define (main) : i64
  0)