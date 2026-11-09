;; Helper for entry_value_scope_j12_reflected_fn_beside_other_struct_ok (#9687).
(defstruct make
  (y i64))

(define (v) : i64
  (let
    [m (make 1)]
    m.y))