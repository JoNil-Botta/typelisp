;; Refs #7817. Exercise the normal inline compilation/run path repeatedly in
;; one process. Warming first excludes fixed intern/reader/IR-name tables; the
;; eight measured entries must not retain per-entry compiler owners or view
;; records. Borrow the same caller-owned roots/target as the real batch driver,
;; and do no reporting between the allocation checkpoints.
(import test_cli_core as tltest)
(import compiler_backend)
(import compiler_driver_core as driver)
(import compiler_load)
(import stdlib.io)
(import stdlib.profile)
(import compiler_owned_view as owned_view)
(import stdlib.vector)
(import (vector.vector String) as cli_svec)

(define (main) : i64
  (let
    [index : i64 0]
    [warm-live : i64 0]
    [roots : cli_svec.Vec (tltest.tltest-roots-for-self-test)]
    [target : String (cfg windows "windows-x86_64" "linux-x86_64")]
    [backend-target : compiler_backend.CompilerBackendTarget
      (cfg
        windows
        compiler_backend.CompilerBackendTarget.Windows
        compiler_backend.CompilerBackendTarget.Linux)]
    (begin
      (compiler_load.compiler-load-session-cache-enable!)
      (compiler_load.compiler-load-session-program-cache-disable!)
      (driver.compiler-driver-reset-file-state!)
      (while (< index 12)
        (begin
          (unless
            (=
              (tltest.tltest-run-batch-run-path
                "tests/inline/test_batch_retention_leaf.tl"
                (owned_view.compiler-owned-shared-view target)
                (owned_view.compiler-owned-shared-view roots)
                1
                backend-target)
              1)
            (io.panic
              "test CLI entry memory: inline entry did not pass one test"))
          (set! index (+ index 1))
          (when (= index 4) (set! warm-live (profile.alloc-live)))))
      (unless
        (> warm-live 0)
        (io.panic "test CLI entry memory: allocation counters are inactive"))
      (unless
        (= (profile.alloc-live) warm-live)
        (io.panic "test CLI entry memory: retained bytes grow between entries"))
      42)))