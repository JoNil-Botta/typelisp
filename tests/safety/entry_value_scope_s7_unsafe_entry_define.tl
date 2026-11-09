;; #9687: an unsafe entry define.
(import entry_value_scope_s7_unsafe_entry_define_nud)

(unsafe
  (define (raw-helper) : i64
    7))

(define (main) : i64
  (entry_value_scope_s7_unsafe_entry_define_nud.n-ud))