;; Refs #7817. Exercise the normal inline compilation/run path repeatedly in
;; one process. Warming first excludes fixed intern/reader/IR-name tables; the
;; eight measured entries must not retain per-entry compiler owners.
(import test_cli_core as tltest)
(import test_cli_core_tests as tltest_tests)
(import compiler_backend)
(import compiler_driver_core as driver)
(import compiler_load)
(import stdlib.io)
(import stdlib.profile)

(define (main) : i64
  (let
    [index : i64 0]
    [warm-live : i64 0]
    [target : String (cfg windows "windows-x86_64" "linux-x86_64")]
    [backend-target : compiler_backend.CompilerBackendTarget
      (cfg
        windows
        compiler_backend.CompilerBackendTarget.Windows
        compiler_backend.CompilerBackendTarget.Linux)]
    (compiler_load.compiler-load-session-cache-enable!)
    (compiler_load.compiler-load-session-program-cache-disable!)
    (driver.compiler-driver-reset-file-state!)
    (while (< index 12)
      (unless
        (=
          (tltest.tltest-run-batch-run-path
            "tests/inline/test_batch_retention_leaf.tl"
            (clone target)
            (tltest_tests.tltest-roots-for-self-test)
            1
            (Scalar)
            backend-target)
          1)
        (io.panic "test CLI entry memory: inline entry did not pass one test"))
      (+= index 1)
      (when (= index 4) (set! warm-live (profile.alloc-live))))
    (unless
      (> warm-live 0)
      (io.panic "test CLI entry memory: allocation counters are inactive"))
    (unless
      (<= (- (profile.alloc-live) warm-live) 1048576)
      (io.panic "test CLI entry memory: retained bytes grow between entries"))
    42))