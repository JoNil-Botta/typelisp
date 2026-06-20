;; compiler_lower_smoke.tl - Runnable smoke for compiler_lower.tl (#446).
(import "../compiler_lower.tl")

(define (main) : i64
  (compiler-lower-self-test))