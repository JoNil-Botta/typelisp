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

(defenum EntryMemoryWorkload
  (Leaf)
  (Heavy)
  (Mixed))

(defstruct EntryMemorySample
  (warm-live i64)
  (final-live i64))

;; Shared by the small regression and the cross-host heavy measurement tool.
;; Inputs/results belong to the caller; every compilation entry owns its own
;; temporary storage. The first four entries warm fixed process-owned tables.
(define (entry-memory-sample [workload : EntryMemoryWorkload] [count : i64]) : EntryMemorySample
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
      (unless
        (>= count 4)
        (io.panic "test entry memory: fewer than four warmup entries"))
      (compiler_load.compiler-load-session-cache-enable!)
      (compiler_load.compiler-load-session-program-cache-disable!)
      (driver.compiler-driver-reset-file-state!)
      (while (< index count)
        (let
          [leaf : bool
            (match workload
              [(EntryMemoryWorkload.Leaf) true]
              [(EntryMemoryWorkload.Heavy) false]
              [(EntryMemoryWorkload.Mixed) (= (% index 2) 1)])]
          (begin
            (unless
              (=
                (tltest.tltest-run-batch-run-path
                  (if leaf
                    "tests/inline/test_batch_retention_leaf.tl"
                    "tests/inline/windows_param_preassign_backend.tl")
                  (owned_view.compiler-owned-shared-view target)
                  (owned_view.compiler-owned-shared-view roots)
                  1
                  backend-target)
                (if leaf
                  1
                  2))
              (io.panic "test CLI entry memory: inline entry count differs"))
            (set! index (+ index 1))
            (when (= index 4) (set! warm-live (profile.alloc-live))))))
      (EntryMemorySample warm-live (profile.alloc-live)))))

(define (main) : i64
  (let
    [sample : EntryMemorySample
      (entry-memory-sample EntryMemoryWorkload.Leaf 12)]
    (begin
      (unless
        (> sample.warm-live 0)
        (io.panic "test CLI entry memory: allocation counters are inactive"))
      (unless
        (= sample.final-live sample.warm-live)
        (io.panic "test CLI entry memory: retained bytes grow between entries"))
      42)))