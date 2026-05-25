;; compiler_ir_types_smoke.tl - Runnable IR type/effect smoke (#1043).
(import "compiler_ir_types.tl")

(define (main) : i64
  (compiler-ir-effect-self-test))