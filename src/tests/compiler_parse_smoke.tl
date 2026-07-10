;; compiler_parse_smoke.tl - Runnable structural smoke for compiler_parse_core.
(import "../compiler_parse_core.tl")
(import compiler_builtin_ids as cbi)

(define (main) : i64
  (begin
    (cbi.compiler-builtin-refresh!)
    (if (= (compiler-diagnostic-self-test) 42)
      (compiler-parse-smoke)
      1)))