;; compiler_symbols_smoke.tl - Runnable smoke for compiler_symbols.tl (#405).

(import "compiler_symbols.tl")

(define (main) : i64
  (compiler-symbols-self-test))