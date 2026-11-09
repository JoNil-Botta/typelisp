;; #9687: an enum constructor, seen from an imported module.
(import entry_value_scope_p03_enum_ne)

(defenum Color
  (Red)
  (Blue))

(define (main) : i64
  (entry_value_scope_p03_enum_ne.n-enum))