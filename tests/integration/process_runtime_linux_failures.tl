;; Deterministic Linux process execution and cleanup fault coverage. refs #7570
(import stdlib.io)
(import stdlib.process)
(import stdlib.process_runtime)
(import stdlib.profile)
(import stdlib.test)

(define process-fd-scan-limit : i64
  4096)

(define (true-command) : process.ProcessCommand
  (process.command "/usr/bin/true" (process.args-empty)))

(define (missing-command) : process.ProcessCommand
  (process.command
    "/definitely_missing_typelisp_process_failure_gate_7570"
    (process.args-empty)))

(define (stdin-command) : process.ProcessCommand
  (process.command-with-stdin
    (process.command "/usr/bin/cat" (process.args-empty))
    "fault-gate-stdin"))

(define (cwd-command) : process.ProcessCommand
  (process.command-with-cwd (true-command) "/tmp"))

(define (printf-command [text : String]) : process.ProcessCommand
  (process.command "/usr/bin/printf" (process.args-single text)))

(define (stdout-stderr-command) : process.ProcessCommand
  (process.command
    "/bin/sh"
    (process.args-cons
      "-c"
      (process.args-single "printf closed-stdout; printf closed-stderr >&2"))))

;: Duplicate one standard descriptor above the process runtime's working range.
(define (save-standard-fd [fd : i64]) : i64
  (let
    [result : i64
      (unsafe
        (syscall 72 fd 1030 64))]
    (if (< result 0)
      (io.panic "failed to save standard descriptor")
      result)))

(define (close-standard-fd [fd : i64]) : unit
  (if (<
    (unsafe
      (syscall 3 fd))
    0)
    (io.panic "failed to close standard descriptor")
    unit))

(define (restore-standard-fd [saved : i64] [fd : i64]) : unit
  (let
    [dup-result : i64
      (unsafe
        (syscall 33 saved fd))]
    [close-result : i64
      (unsafe
        (syscall 3 saved))]
    (if (or (not (= dup-result fd)) (< close-result 0))
      (io.panic "failed to restore standard descriptor")
      unit)))

;: Close the standard descriptors selected by mask bits stdin=1, stdout=2,
;: stderr=4 while one captured process runs, then restore them before returning.
(define (output-with-closed-standard-fds
  [command : process.ProcessCommand]
  [mask : i64]) : process.ResultProcessOutput
  (let
    [close-stdin : bool (not (= (bit-and mask 1) 0))]
    [close-stdout : bool (not (= (bit-and mask 2) 0))]
    [close-stderr : bool (not (= (bit-and mask 4) 0))]
    [saved-stdin : i64
      (if close-stdin
        (save-standard-fd 0)
        -1)]
    [saved-stdout : i64
      (if close-stdout
        (save-standard-fd 1)
        -1)]
    [saved-stderr : i64
      (if close-stderr
        (save-standard-fd 2)
        -1)]
    (begin
      (if close-stdin
        (close-standard-fd 0)
        unit)
      (if close-stdout
        (close-standard-fd 1)
        unit)
      (if close-stderr
        (close-standard-fd 2)
        unit)
      (let
        [result : process.ResultProcessOutput (process.output command)]
        (begin
          (if close-stdin
            (restore-standard-fd saved-stdin 0)
            unit)
          (if close-stdout
            (restore-standard-fd saved-stdout 1)
            unit)
          (if close-stderr
            (restore-standard-fd saved-stderr 2)
            unit)
          result)))))

(define (assert-string-owned-eq
  [actual : String]
  [expected : String]
  [label : String]) : unit
  (test.assert-string-eq (& actual) (& expected) label))

(define (assert-output-error
  [result : process.ResultProcessOutput]
  [expected : String]
  [label : String]) : unit
  (assert-string-owned-eq
    (process.result-error-message-or result "<success>")
    expected
    label))

(define (assert-child-error
  [result : process.ResultProcessChild]
  [expected : String]
  [label : String]) : unit
  (assert-string-owned-eq
    (process.child-result-error-message-or result "<success>")
    expected
    label))

(define (assert-output-ok
  [result : process.ResultProcessOutput]
  [status : i64]
  [stdout : String]
  [stderr : String]
  [label : String]) : unit
  (test.assert-true
    (process.result-output-eq? result status stdout stderr)
    label))

(define (child-or-panic [result : process.ResultProcessChild] [label : String]) : process.ProcessChild
  (let
    [info : process.ProcessChildInfo (process.child-result-info (clone result))]
    (if (process.child-info-ok? info)
      (process.ProcessChild
        (process.child-info-pid info)
        (process.child-info-stdout-handle info)
        (process.child-info-stderr-handle info))
      (io.panic label))))

(define (assert-no-resource-growth [baseline-fds : i64] [label : String]) : unit
  (begin
    (test.assert-i64-eq
      (process_runtime.linux-test-open-fd-count process-fd-scan-limit)
      baseline-fds
      (clone label))
    (test.assert-true (process_runtime.linux-test-no-children?) label)))

;: Every injected failure is followed by a clean success and resource proof.
(define (assert-clean-follow-up [baseline-fds : i64] [label : String]) : unit
  (begin
    (process_runtime.linux-test-reset!)
    (assert-output-ok (process.output (true-command)) 0 "" "" (clone label))
    (assert-no-resource-growth baseline-fds label)))

(define (assert-output-failure-followed-by-success
  [command : process.ProcessCommand]
  [expected : String]
  [baseline-fds : i64]
  [label : String]) : unit
  (begin
    (assert-output-error (process.output command) expected (clone label))
    (assert-clean-follow-up baseline-fds label)))

(define (assert-inherit-failure-followed-by-success
  [command : process.ProcessCommand]
  [expected : String]
  [baseline-fds : i64]
  [label : String]) : unit
  (begin
    (assert-output-error (process.inherit command) expected (clone label))
    (assert-clean-follow-up baseline-fds label)))

(define (assert-start-failure-followed-by-success
  [command : process.ProcessCommand]
  [expected : String]
  [baseline-fds : i64]
  [label : String]) : unit
  (begin
    (assert-child-error (process.start command) expected (clone label))
    (assert-clean-follow-up baseline-fds label)))

(define (run-parent-faults [baseline-fds : i64]) : unit
  (begin
    (process_runtime.linux-test-reset!)
    (process_runtime.linux-test-fail-on!
      process_runtime.process-linux-syscall-pipe
      1
      24)
    (assert-output-failure-followed-by-success
      (stdin-command)
      "process: spawn failed"
      baseline-fds
      "stdin pipe failure")
    (process_runtime.linux-test-reset!)
    (process_runtime.linux-test-fail-on!
      process_runtime.process-linux-syscall-pipe
      2
      24)
    (assert-output-failure-followed-by-success
      (stdin-command)
      "process: spawn failed"
      baseline-fds
      "exec pipe failure")
    (process_runtime.linux-test-reset!)
    (process_runtime.linux-test-fail-on!
      process_runtime.process-linux-syscall-memfd
      1
      24)
    (assert-output-failure-followed-by-success
      (true-command)
      "process: spawn failed"
      baseline-fds
      "stdout memfd failure")
    (process_runtime.linux-test-reset!)
    (process_runtime.linux-test-fail-on!
      process_runtime.process-linux-syscall-memfd
      2
      24)
    (assert-output-failure-followed-by-success
      (true-command)
      "process: spawn failed"
      baseline-fds
      "stderr memfd failure")
    (process_runtime.linux-test-reset!)
    (process_runtime.linux-test-fail-on!
      process_runtime.process-linux-syscall-memfd
      2
      24)
    (process_runtime.linux-test-fail-second-on!
      process_runtime.process-linux-syscall-close
      1
      9)
    (assert-output-failure-followed-by-success
      (true-command)
      "process: spawn failed; cleanup: close failed (-9)"
      baseline-fds
      "pre-spawn primary and close cleanup failure")
    (process_runtime.linux-test-reset!)
    (process_runtime.linux-test-fail-on!
      process_runtime.process-linux-syscall-vfork
      1
      11)
    (assert-output-failure-followed-by-success
      (true-command)
      "process: spawn failed"
      baseline-fds
      "vfork failure")
    (process_runtime.linux-test-reset!)
    (process_runtime.linux-test-fail-on!
      process_runtime.process-linux-syscall-close
      1
      9)
    (assert-output-failure-followed-by-success
      (true-command)
      "process: close failed (-9)"
      baseline-fds
      "parent close failure")
    (process_runtime.linux-test-reset!)
    (process_runtime.linux-test-fail-on!
      process_runtime.process-linux-syscall-sigaction
      1
      22)
    (assert-output-failure-followed-by-success
      (stdin-command)
      "process: stdin failed (-22)"
      baseline-fds
      "sigaction install failure")
    (process_runtime.linux-test-reset!)
    (process_runtime.linux-test-fail-on!
      process_runtime.process-linux-syscall-sigaction
      2
      22)
    (assert-output-failure-followed-by-success
      (stdin-command)
      "process: stdin failed (-22)"
      baseline-fds
      "sigaction restore failure")
    (process_runtime.linux-test-reset!)
    (process_runtime.linux-test-fail-on!
      process_runtime.process-linux-syscall-stdin-write
      1
      4)
    (assert-output-ok
      (process.output (stdin-command))
      0
      "fault-gate-stdin"
      ""
      "stdin EINTR retry")
    (assert-no-resource-growth baseline-fds "stdin EINTR resources")
    (process_runtime.linux-test-reset!)
    (process_runtime.linux-test-set-write-max! 2)
    (assert-output-ok
      (process.output (stdin-command))
      0
      "fault-gate-stdin"
      ""
      "stdin partial writes")
    (test.assert-true
      (>
        (process_runtime.linux-test-call-count
          process_runtime.process-linux-syscall-stdin-write)
        1)
      "stdin partial write count")
    (assert-no-resource-growth baseline-fds "stdin partial resources")
    (process_runtime.linux-test-reset!)
    (process_runtime.linux-test-fail-on!
      process_runtime.process-linux-syscall-stdin-write
      1
      5)
    (assert-output-failure-followed-by-success
      (stdin-command)
      "process: stdin failed (-5)"
      baseline-fds
      "stdin write failure")
    (process_runtime.linux-test-reset!)
    (process_runtime.linux-test-fail-on!
      process_runtime.process-linux-syscall-stdin-write
      1
      32)
    (assert-output-ok
      (process.output
        (process.command-with-stdin (true-command) "ignored-broken-pipe"))
      0
      ""
      ""
      "stdin EPIPE tolerated")
    (assert-no-resource-growth baseline-fds "stdin EPIPE resources")
    (process_runtime.linux-test-reset!)
    (process_runtime.linux-test-fail-on!
      process_runtime.process-linux-syscall-wait
      1
      4)
    (assert-output-ok
      (process.output (true-command))
      0
      ""
      ""
      "wait EINTR retry")
    (test.assert-i64-eq
      (process_runtime.linux-test-call-count
        process_runtime.process-linux-syscall-wait)
      2
      "wait EINTR call count")
    (assert-no-resource-growth baseline-fds "wait EINTR resources")
    (process_runtime.linux-test-reset!)
    (process_runtime.linux-test-fail-on!
      process_runtime.process-linux-syscall-wait
      1
      10)
    (assert-output-failure-followed-by-success
      (true-command)
      "process: wait failed"
      baseline-fds
      "wait failure cleanup")
    (process_runtime.linux-test-reset!)
    (process_runtime.linux-test-fail-on!
      process_runtime.process-linux-syscall-stdin-write
      1
      5)
    (process_runtime.linux-test-fail-second-on!
      process_runtime.process-linux-syscall-wait
      1
      10)
    (assert-output-failure-followed-by-success
      (stdin-command)
      "process: stdin failed (-5); cleanup: wait failed (-10)"
      baseline-fds
      "primary stdin and secondary wait failure")
    (process_runtime.linux-test-reset!)
    (process_runtime.linux-test-fail-on!
      process_runtime.process-linux-syscall-close
      1
      9)
    (process_runtime.linux-test-fail-second-on!
      process_runtime.process-linux-syscall-stdin-write
      1
      5)
    (assert-output-failure-followed-by-success
      (stdin-command)
      "process: stdin failed (-5); cleanup: close failed (-9)"
      baseline-fds
      "early cleanup failure does not hide primary stdin failure")))

(define (run-standard-fd-collisions [baseline-fds : i64]) : unit
  (begin
    (process_runtime.linux-test-reset!)
    (assert-output-ok
      (output-with-closed-standard-fds (printf-command "closed-stdout") 2)
      0
      "closed-stdout"
      ""
      "closed caller stdout capture")
    (assert-no-resource-growth baseline-fds "closed caller stdout resources")
    (process_runtime.linux-test-reset!)
    (assert-output-ok
      (output-with-closed-standard-fds (stdout-stderr-command) 4)
      0
      "closed-stdout"
      "closed-stderr"
      "closed caller stderr capture")
    (assert-no-resource-growth baseline-fds "closed caller stderr resources")
    (process_runtime.linux-test-reset!)
    (assert-output-ok
      (output-with-closed-standard-fds (stdout-stderr-command) 3)
      0
      "closed-stdout"
      "closed-stderr"
      "capture descriptor cross-wiring")
    (assert-no-resource-growth baseline-fds "capture cross-wiring resources")
    (process_runtime.linux-test-reset!)
    (assert-output-ok
      (output-with-closed-standard-fds (stdin-command) 7)
      0
      "fault-gate-stdin"
      ""
      "stdin descriptor zero wiring")
    (assert-no-resource-growth baseline-fds "stdin descriptor zero resources")))

(define (run-child-fault
  [kind : i64]
  [command : process.ProcessCommand]
  [expected : String]
  [baseline-fds : i64]
  [label : String]) : unit
  (begin
    (process_runtime.linux-test-reset!)
    (process_runtime.linux-test-child-fail-on! kind 5)
    (assert-output-failure-followed-by-success
      command
      expected
      baseline-fds
      label)))

(define (run-child-faults [baseline-fds : i64]) : unit
  (begin
    (run-child-fault
      process_runtime.process-linux-child-syscall-close-exec-read
      (true-command)
      "process: child setup failed (-1)"
      baseline-fds
      "child close exec read")
    (run-child-fault
      process_runtime.process-linux-child-syscall-close-stdin-write
      (stdin-command)
      "process: child setup failed (-2)"
      baseline-fds
      "child close stdin write")
    (run-child-fault
      process_runtime.process-linux-child-syscall-dup-stdin
      (stdin-command)
      "process: child setup failed (-3)"
      baseline-fds
      "child dup stdin")
    (run-child-fault
      process_runtime.process-linux-child-syscall-close-stdin-read
      (stdin-command)
      "process: child setup failed (-4)"
      baseline-fds
      "child close stdin read")
    (run-child-fault
      process_runtime.process-linux-child-syscall-dup-stdout
      (true-command)
      "process: child setup failed (-5)"
      baseline-fds
      "child dup stdout")
    (run-child-fault
      process_runtime.process-linux-child-syscall-dup-stderr
      (true-command)
      "process: child setup failed (-6)"
      baseline-fds
      "child dup stderr")
    (run-child-fault
      process_runtime.process-linux-child-syscall-close-stdout
      (true-command)
      "process: child setup failed (-7)"
      baseline-fds
      "child close stdout")
    (run-child-fault
      process_runtime.process-linux-child-syscall-close-stderr
      (true-command)
      "process: child setup failed (-8)"
      baseline-fds
      "child close stderr")
    (run-child-fault
      process_runtime.process-linux-child-syscall-chdir
      (cwd-command)
      "process: child setup failed (-9)"
      baseline-fds
      "child chdir")
    (run-child-fault
      process_runtime.process-linux-child-syscall-exec
      (true-command)
      "process: spawn failed"
      baseline-fds
      "child exec failure")))

(define (run-exec-channel-faults [baseline-fds : i64]) : unit
  (begin
    (process_runtime.linux-test-reset!)
    (process_runtime.linux-test-fail-on!
      process_runtime.process-linux-syscall-exec-read
      1
      4)
    (assert-output-failure-followed-by-success
      (missing-command)
      "process: spawn failed"
      baseline-fds
      "exec read EINTR")
    (process_runtime.linux-test-reset!)
    (process_runtime.linux-test-set-read-max! 1)
    (assert-output-failure-followed-by-success
      (missing-command)
      "process: spawn failed"
      baseline-fds
      "exec partial reads")
    (process_runtime.linux-test-reset!)
    (process_runtime.linux-test-fail-on!
      process_runtime.process-linux-syscall-exec-read
      1
      5)
    (assert-output-failure-followed-by-success
      (true-command)
      "process: exec status failed (-5)"
      baseline-fds
      "exec read failure")
    (process_runtime.linux-test-reset!)
    (process_runtime.linux-test-set-marker-mode! 1)
    (assert-output-failure-followed-by-success
      (missing-command)
      "process: exec status failed (-71)"
      baseline-fds
      "partial exec record")
    (process_runtime.linux-test-reset!)
    (process_runtime.linux-test-set-marker-mode! 2)
    (assert-output-failure-followed-by-success
      (missing-command)
      "process: exec status failed (-71)"
      baseline-fds
      "malformed exec record")
    (process_runtime.linux-test-reset!)
    (process_runtime.linux-test-set-marker-mode! 3)
    (assert-output-failure-followed-by-success
      (missing-command)
      "process: exec status failed (-71)"
      baseline-fds
      "oversized exec record")
    (process_runtime.linux-test-reset!)
    (process_runtime.linux-test-set-marker-mode! 4)
    (assert-output-failure-followed-by-success
      (missing-command)
      "process: spawn failed"
      baseline-fds
      "partial exec record writes")
    (process_runtime.linux-test-reset!)
    (process_runtime.linux-test-set-marker-mode! 5)
    (assert-output-failure-followed-by-success
      (missing-command)
      "process: spawn failed"
      baseline-fds
      "interrupted exec record write")))

(define (run-capture-faults [baseline-fds : i64]) : unit
  (begin
    (process_runtime.linux-test-reset!)
    (process_runtime.linux-test-fail-on!
      process_runtime.process-linux-syscall-capture-seek
      1
      4)
    (assert-output-ok
      (process.output (printf-command "seek-eintr"))
      0
      "seek-eintr"
      ""
      "capture seek EINTR")
    (assert-no-resource-growth baseline-fds "capture seek EINTR resources")
    (process_runtime.linux-test-reset!)
    (process_runtime.linux-test-fail-on!
      process_runtime.process-linux-syscall-capture-seek
      1
      5)
    (assert-output-failure-followed-by-success
      (printf-command "seek-error")
      "process: stdout capture failed (-5)"
      baseline-fds
      "stdout seek failure")
    (process_runtime.linux-test-reset!)
    (process_runtime.linux-test-fail-on!
      process_runtime.process-linux-syscall-capture-seek
      3
      5)
    (assert-output-failure-followed-by-success
      (printf-command "stderr-seek")
      "process: stderr capture failed (-5)"
      baseline-fds
      "stderr seek failure")
    (process_runtime.linux-test-reset!)
    (process_runtime.linux-test-set-read-max! 1)
    (assert-output-ok
      (process.output (printf-command "partial-read"))
      0
      "partial-read"
      ""
      "capture partial reads")
    (test.assert-true
      (>
        (process_runtime.linux-test-call-count
          process_runtime.process-linux-syscall-capture-read)
        1)
      "capture partial read count")
    (assert-no-resource-growth baseline-fds "capture partial resources")
    (process_runtime.linux-test-reset!)
    (process_runtime.linux-test-fail-on!
      process_runtime.process-linux-syscall-capture-read
      1
      4)
    (assert-output-ok
      (process.output (printf-command "read-eintr"))
      0
      "read-eintr"
      ""
      "capture read EINTR")
    (assert-no-resource-growth baseline-fds "capture read EINTR resources")
    (process_runtime.linux-test-reset!)
    (process_runtime.linux-test-fail-on!
      process_runtime.process-linux-syscall-capture-read
      1
      5)
    (assert-output-failure-followed-by-success
      (printf-command "read-error")
      "process: stdout capture failed (-5)"
      baseline-fds
      "capture read failure")
    (process_runtime.linux-test-reset!)
    (process_runtime.linux-test-fail-on!
      process_runtime.process-linux-syscall-capture-read
      1
      0)
    (assert-output-failure-followed-by-success
      (printf-command "zero-progress")
      "process: stdout capture failed (-71)"
      baseline-fds
      "capture zero progress")
    (process_runtime.linux-test-reset!)
    (process_runtime.linux-test-fail-on!
      process_runtime.process-linux-syscall-capture-read
      1
      5)
    (process_runtime.linux-test-fail-second-on!
      process_runtime.process-linux-syscall-close
      3
      9)
    (assert-output-failure-followed-by-success
      (printf-command "primary-secondary")
      "process: stdout capture failed (-5); cleanup: close failed (-9)"
      baseline-fds
      "capture primary and close cleanup failure")))

(define (run-async-and-inherited-faults [baseline-fds : i64]) : unit
  (begin
    (process_runtime.linux-test-reset!)
    (process_runtime.linux-test-fail-on!
      process_runtime.process-linux-syscall-exec-read
      1
      5)
    (assert-start-failure-followed-by-success
      (true-command)
      "process: exec status failed (-5)"
      baseline-fds
      "async exec read failure")
    (process_runtime.linux-test-reset!)
    (assert-start-failure-followed-by-success
      (missing-command)
      "process: spawn failed"
      baseline-fds
      "async exec failure")
    (process_runtime.linux-test-reset!)
    (let
      [child : process.ProcessChild
        (child-or-panic
          (process.start (printf-command "async-capture"))
          "async start failed")]
      (begin
        (process_runtime.linux-test-set-read-max! 1)
        (process_runtime.linux-test-fail-on!
          process_runtime.process-linux-syscall-capture-read
          1
          4)
        (assert-output-ok
          (process.wait child)
          0
          "async-capture"
          ""
          "async wait short read and EINTR")
        (assert-no-resource-growth baseline-fds "async wait resources")))
    (process_runtime.linux-test-reset!)
    (let
      [child : process.ProcessChild
        (child-or-panic
          (process.start (true-command))
          "async wait failure start failed")]
      (begin
        (process_runtime.linux-test-fail-on!
          process_runtime.process-linux-syscall-wait
          1
          10)
        (assert-output-error
          (process.wait child)
          "process: wait failed"
          "async wait failure")
        (assert-clean-follow-up baseline-fds "async wait failure cleanup")))
    (process_runtime.linux-test-reset!)
    (process_runtime.linux-test-fail-on!
      process_runtime.process-linux-syscall-wait
      1
      4)
    (assert-output-ok
      (process.inherit (true-command))
      0
      ""
      ""
      "inherited wait EINTR")
    (assert-no-resource-growth baseline-fds "inherited wait EINTR resources")
    (process_runtime.linux-test-reset!)
    (process_runtime.linux-test-set-marker-mode! 1)
    (assert-inherit-failure-followed-by-success
      (missing-command)
      "process: exec status failed (-71)"
      baseline-fds
      "inherited malformed exec channel")
    (process_runtime.linux-test-reset!)
    (process_runtime.linux-test-fail-on!
      process_runtime.process-linux-syscall-stdin-write
      1
      5)
    (assert-inherit-failure-followed-by-success
      (stdin-command)
      "process: stdin failed (-5)"
      baseline-fds
      "inherited stdin failure")))

(define (run-stress [remaining : i64] [baseline-fds : i64]) : unit
  (if (= remaining 0)
    unit
    (begin
      (process_runtime.linux-test-reset!)
      (process_runtime.linux-test-set-marker-mode! 1)
      (assert-output-error
        (process.output (missing-command))
        "process: exec status failed (-71)"
        "stress malformed record")
      (assert-clean-follow-up baseline-fds "stress cleanup")
      (run-stress (- remaining 1) baseline-fds))))

(define (run-metrics [baseline-fds : i64]) : unit
  (begin
    (process_runtime.linux-test-reset!)
    (let
      [before-ticks : i64 (profile.now-ticks)]
      [before-alloc : i64 (profile.alloc-total)]
      [result : process.ResultProcessOutput
        (process.output (printf-command "metrics"))]
      [elapsed : i64 (- (profile.now-ticks) before-ticks)]
      [allocated : i64 (- (profile.alloc-total) before-alloc)]
      (begin
        (assert-output-ok result 0 "metrics" "" "metrics output")
        (assert-no-resource-growth baseline-fds "metrics resources")
        (test.assert-i64-eq
          (process_runtime.linux-test-call-count
            process_runtime.process-linux-syscall-pipe)
          1
          "metrics pipe syscalls")
        (test.assert-i64-eq
          (process_runtime.linux-test-call-count
            process_runtime.process-linux-syscall-memfd)
          2
          "metrics memfd syscalls")
        (test.assert-i64-eq
          (process_runtime.linux-test-call-count
            process_runtime.process-linux-syscall-vfork)
          1
          "metrics vfork syscalls")
        (test.assert-i64-eq
          (process_runtime.linux-test-call-count
            process_runtime.process-linux-syscall-wait)
          1
          "metrics wait syscalls")
        (test.assert-i64-eq
          (process_runtime.linux-test-call-count
            process_runtime.process-linux-syscall-exec-read)
          1
          "metrics exec read syscalls")
        (test.assert-i64-eq
          (process_runtime.linux-test-call-count
            process_runtime.process-linux-syscall-capture-seek)
          4
          "metrics capture seek syscalls")
        (test.assert-i64-eq
          (process_runtime.linux-test-call-count
            process_runtime.process-linux-syscall-capture-read)
          1
          "metrics capture read syscalls")
        (test.assert-i64-eq
          (process_runtime.linux-test-call-count
            process_runtime.process-linux-syscall-close)
          4
          "metrics close syscalls")
        (test.assert-true (> elapsed 0) "metrics elapsed ticks")
        (test.assert-true (> allocated 0) "metrics allocated bytes")
        (io.println
          "process-linux-metrics ticks={} alloc-bytes={} fds={} zombies=0 syscalls=15"
          elapsed
          allocated
          baseline-fds)))))

(define (main) : i64
  (let
    [baseline-fds : i64
      (process_runtime.linux-test-open-fd-count process-fd-scan-limit)]
    (begin
      (test.assert-true
        (process_runtime.linux-test-no-children?)
        "initial child state")
      (run-parent-faults baseline-fds)
      (run-standard-fd-collisions baseline-fds)
      (run-child-faults baseline-fds)
      (run-exec-channel-faults baseline-fds)
      (run-capture-faults baseline-fds)
      (run-async-and-inherited-faults baseline-fds)
      (run-stress 20 baseline-fds)
      (run-metrics baseline-fds)
      42)))