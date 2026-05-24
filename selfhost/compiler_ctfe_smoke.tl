;; Smoke entry for the selfhost CTFE evaluator (#719). `main` returns 42 when

;; the `compiler_ctfe.tl` self-test battery passes (scalar folding, control

;; flow, rejection diagnostics, and fuel exhaustion).

(import "compiler_ctfe.tl")

(define (main) : i64
  (compiler-ctfe-self-test))