;; compiler_driver_base_transients_smoke.tl - Driver base-transient state
;; isolation smoke: builtin/CTFE ids and lower scratch/IR arenas are owned by
;; each driver state (refs #4723).
(import compiler_driver_smoke_tests)

(define (main) : i64
  (compiler_driver_smoke_tests.compiler-driver-base-transients-smoke-main))