;; #9687: an extern, seen from an imported module.
(import entry_value_scope_p19_extern_nx)

(extern (getpid) : i32)

(define (main) : i64
  (entry_value_scope_p19_extern_nx.n-x))