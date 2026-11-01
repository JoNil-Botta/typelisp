;; A dependency-free, out-of-line fatal diagnostic for compiler invariants.
;; Callers pass a static message naming the table and operation, with a newline.
;; The runtime writes it unchanged and terminates with status 134 on both hosts.
(extern (compiler-abort [message : String]) : never (:symbol "tl_abort_string"))