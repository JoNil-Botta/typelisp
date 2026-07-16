;; compiler_symbols_smoke.tl - Runnable smoke for compiler_symbols.tl.
(import "../compiler_symbols.tl")
(import compiler_builtin_ids as cbi)

(define (main) : i64
  (begin
    (cbi.compiler-builtin-initialize-for-parse!)
    (compiler-symbols-self-test)))