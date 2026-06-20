;; compiler_parse_smoke.tl - Runnable structural smoke for compiler_parse_core.
(import "../compiler_parse_core.tl")

(define (main) : i64
  (if (= (compiler-diagnostic-self-test) 42)
    (compiler-parse-smoke)
    1))