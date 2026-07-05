;; compiler_symbols_smoke.tl - Runnable smoke for compiler_symbols.tl.
(import "../compiler_symbols.tl")

(define (main) : i64
  (compiler-symbols-self-test))