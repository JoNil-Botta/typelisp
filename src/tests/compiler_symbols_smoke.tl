;; compiler_symbols_smoke.tl - Runnable smoke for compiler_symbols.tl.
(import compiler_symbols_tests as sym_tests)
(import compiler_builtin_ids as cbi)

(define (main) : i64
  (cbi.compiler-builtin-initialize-for-parse!)
  (sym_tests.compiler-symbols-self-test))