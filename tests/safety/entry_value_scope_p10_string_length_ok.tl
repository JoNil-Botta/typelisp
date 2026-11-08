;; #9687: a builtin-dispatched name, seen from an imported module.
(import entry_value_scope_p10_string_length_ok_n)

(define (string-length [s : (& s str)]) : i64
  100)

(define (main) : i64
  (entry_value_scope_p10_string_length_ok_n.n-prel))