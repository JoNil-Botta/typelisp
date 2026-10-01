;; Native contract coverage for rooted Linux sidecar guards (#7559).
;; scripts/verify-fs-rooted-linux.sh prepares each mode's tree and runs the
;; `hold`, `try` and `die` modes as separate processes.
(import stdlib.byte_buf)
(import stdlib.fs_rooted_linux as rooted)
(import stdlib.io)
(import stdlib.string)
(import stdlib.time)

(define (result-code [result : rooted.FsLinuxRootedResult]) : i64
  (match result
    [(rooted.LinuxRootedOk) 0]
    [(rooted.LinuxRootedInvalidComponent) 1]
    [(rooted.LinuxRootedNotFound) 2]
    [(rooted.LinuxRootedAlreadyExists) 3]
    [(rooted.LinuxRootedUnsafeResolution) 4]
    [(rooted.LinuxRootedWrongKind) 5]
    [(rooted.LinuxRootedPermissionDenied) 6]
    [(rooted.LinuxRootedUnsupported) 7]
    [(rooted.LinuxRootedIoFailure) 8]
    [(rooted.LinuxRootedCancelled) 9]
    [(rooted.LinuxRootedWriteFailure) 10]
    [(rooted.LinuxRootedModeFailure) 11]
    [(rooted.LinuxRootedFlushFailure) 12]
    [(rooted.LinuxRootedCloseFailure) 13]
    [(rooted.LinuxRootedClosed) 14]
    [(rooted.LinuxRootedCrossDevice) 15]
    [(rooted.LinuxRootedDirectoryNotEmpty) 16]
    [(rooted.LinuxRootedInvalidLength) 17]
    [(rooted.LinuxRootedLengthMismatch) 18]
    [(rooted.LinuxRootedReadFailure) 19]
    [(rooted.LinuxRootedIdentityChanged) 20]
    [(rooted.LinuxRootedSourceChanged) 21]
    [(rooted.LinuxRootedInvalidPermissions) 22]
    [(rooted.LinuxRootedModeMismatch) 23]
    [(rooted.LinuxRootedLockConflict) 24]))

(define (finish-is?
  [result : rooted.FsLinuxRootedFinishResult]
  [operation : i64]
  [close : i64]) : bool
  (and
    (= (result-code (rooted.linux-rooted-finish-operation result)) operation)
    (= (result-code (rooted.linux-rooted-finish-close result)) close)))

(define (release-is?
  [release : rooted.FsLinuxRootedGuardRelease]
  [unlock : i64]
  [close : i64]) : bool
  (and
    (= (result-code (rooted.linux-rooted-guard-release-unlock release)) unlock)
    (= (result-code (rooted.linux-rooted-guard-release-close release)) close)))

(define (cancel-now) : bool
  true)

(define (acquire
  [root : (& root rooted.FsLinuxRootedDirectory)]
  [component : (& component str)]) : rooted.FsLinuxRootedGuard
  (rooted.linux-rooted-guard-acquire
    root
    component
    rooted.linux-rooted-never-cancelled))

;; Acquisition result code of a guard on `component`, released afterwards.
(define (acquire-code
  [root : (& root rooted.FsLinuxRootedDirectory)]
  [component : (& component str)]) : i64
  (with
    ([guard (acquire root component) rooted.cleanup-linux-rooted-guard])
    (let
      [code : i64 (result-code (rooted.linux-rooted-guard-result (& guard)))]
      (begin
        (rooted.linux-rooted-guard-release! (&mut guard))
        code))))

(define (create-text
  [directory : (& directory rooted.FsLinuxRootedDirectory)]
  [component : String]
  [contents : String]) : rooted.FsLinuxRootedResult
  (with
    ([file
        (rooted.linux-rooted-create-file
          directory
          (& component)
          rooted.linux-rooted-never-cancelled)
        rooted.cleanup-linux-rooted-file])
    (if (not (rooted.linux-rooted-file-open? (& file)))
      (rooted.linux-rooted-file-result (& file))
      (let
        [finished : rooted.FsLinuxRootedFinishResult
          (rooted.linux-rooted-file-finish!
            (&mut file)
            (byte_buf.str-as-bytes (& contents))
            (string-length (& contents))
            rooted.LinuxRootedRegularFile
            true
            rooted.linux-rooted-never-cancelled)]
        (if (rooted.linux-rooted-result-ok?
          (rooted.linux-rooted-finish-operation finished))
          (rooted.linux-rooted-finish-close finished)
          (rooted.linux-rooted-finish-operation finished))))))

;; Lock, conflict, revalidate, release and reacquire one created sidecar.
(define (check-lifecycle [root : (& root rooted.FsLinuxRootedDirectory)]) : i64
  (with
    ([guard (acquire root "lock") rooted.cleanup-linux-rooted-guard])
    (cond
      [(not (= (result-code (rooted.linux-rooted-guard-result (& guard))) 0))
        10]
      [(not (rooted.linux-rooted-guard-locked? (& guard))) 11]
      ;; A second open file description in the same process conflicts.
      [(not (= (acquire-code root "lock") 24)) 12]
      [(not
          (finish-is?
            (rooted.linux-rooted-guard-revalidate
              root
              "lock"
              (& guard)
              rooted.linux-rooted-never-cancelled)
            0
            0))
        13]
      [(not
          (finish-is?
            (rooted.linux-rooted-guard-revalidate
              root
              "lock"
              (& guard)
              cancel-now)
            9
            14))
        14]
      [(not (release-is? (rooted.linux-rooted-guard-release! (&mut guard)) 0 0))
        15]
      [(rooted.linux-rooted-guard-locked? (& guard)) 16]
      [(not
          (release-is? (rooted.linux-rooted-guard-release! (&mut guard)) 14 0))
        17]
      [(not
          (finish-is?
            (rooted.linux-rooted-guard-revalidate
              root
              "lock"
              (& guard)
              rooted.linux-rooted-never-cancelled)
            14
            14))
        18]
      [(not (= (acquire-code root "lock") 0)) 19]
      [else 0])))

;; Leaving a guard's scope without releasing it closes its descriptor, which
;; releases the lock.
(define (check-cleanup-releases [root : (& root rooted.FsLinuxRootedDirectory)]) : i64
  (begin
    (with
      ([scoped (acquire root "scoped-lock") rooted.cleanup-linux-rooted-guard])
      (if (rooted.linux-rooted-guard-locked? (& scoped))
        unit
        unit))
    (if (= (acquire-code root "scoped-lock") 0)
      0
      20)))

;; The harness prepares `dir-sidecar` (directory), `link-sidecar` (symlink),
;; `fifo-sidecar` (FIFO), `linked-sidecar` (two names) and `shared-sidecar`
;; (mode 0664).
(define (check-policy [root : (& root rooted.FsLinuxRootedDirectory)]) : i64
  (cond
    [(not (= (acquire-code root "dir-sidecar") 5)) 30]
    [(not (= (acquire-code root "link-sidecar") 4)) 31]
    [(not (= (acquire-code root "fifo-sidecar") 5)) 32]
    [(not (= (acquire-code root "linked-sidecar") 7)) 33]
    [(not (= (acquire-code root "shared-sidecar") 7)) 34]
    [(not (= (acquire-code root "a/b") 1)) 35]
    [(not
        (with
          ([cancelled
              (rooted.linux-rooted-guard-acquire
                root
                "never-created"
                cancel-now)
              rooted.cleanup-linux-rooted-guard])
          (= (result-code (rooted.linux-rooted-guard-result (& cancelled))) 9)))
      36]
    [else 0]))

;; Replacing or removing a locked sidecar's name is detected, never reported
;; as still serialized.
(define (check-substitution [root : (& root rooted.FsLinuxRootedDirectory)]) : i64
  (with
    ([guard (acquire root "swap") rooted.cleanup-linux-rooted-guard])
    (cond
      [(not (rooted.linux-rooted-guard-locked? (& guard))) 40]
      [(not
          (rooted.linux-rooted-result-ok?
            (create-text root "swap-replacement" "replacement")))
        41]
      [(not
          (rooted.linux-rooted-result-ok?
            (rooted.linux-rooted-rename-replace
              root
              "swap-replacement"
              root
              "swap"
              rooted.linux-rooted-never-cancelled)))
        42]
      [(not
          (finish-is?
            (rooted.linux-rooted-guard-revalidate
              root
              "swap"
              (& guard)
              rooted.linux-rooted-never-cancelled)
            20
            0))
        43]
      [(not
          (rooted.linux-rooted-result-ok?
            (rooted.linux-rooted-unlink-entry
              root
              "swap"
              rooted.linux-rooted-never-cancelled)))
        44]
      [(not
          (finish-is?
            (rooted.linux-rooted-guard-revalidate
              root
              "swap"
              (& guard)
              rooted.linux-rooted-never-cancelled)
            2
            14))
        45]
      [(not (release-is? (rooted.linux-rooted-guard-release! (&mut guard)) 0 0))
        46]
      [else 0])))

(define (run-guard [root : (& root rooted.FsLinuxRootedDirectory)]) : i64
  (let
    [lifecycle : i64 (check-lifecycle root)]
    (if (not (= lifecycle 0))
      lifecycle
      (let
        [cleanup : i64 (check-cleanup-releases root)]
        (if (not (= cleanup 0))
          cleanup
          (let
            [policy : i64 (check-policy root)]
            (if (not (= policy 0))
              policy
              (check-substitution root))))))))

;; 0 when releasing `guard` unlocks and closes it, else `failure`. A
;; function keeps this choice out of the `with` bodies below (#8290).
(define (release-status
  [guard : (&mut guard rooted.FsLinuxRootedGuard)]
  [failure : i64]) : i64
  (if (release-is? (rooted.linux-rooted-guard-release! guard) 0 0)
    0
    failure))

;; Hold the shared lock, announce it with `held`, keep it for the harness's
;; competing `try`, then release it explicitly.
(define (run-hold [root : (& root rooted.FsLinuxRootedDirectory)]) : i64
  (with
    ([guard (acquire root "shared-lock") rooted.cleanup-linux-rooted-guard])
    (cond
      [(not (rooted.linux-rooted-guard-locked? (& guard))) 50]
      [(not (rooted.linux-rooted-result-ok? (create-text root "held" "held")))
        51]
      [else
        (begin
          (time.sleep-ms 3000)
          (release-status (&mut guard) 52))])))

;; One attempt on the shared lock: 0 when acquired and released, 60 on a
;; conflict.
(define (run-try [root : (& root rooted.FsLinuxRootedDirectory)]) : i64
  (with
    ([guard (acquire root "shared-lock") rooted.cleanup-linux-rooted-guard])
    (let
      [code : i64 (result-code (rooted.linux-rooted-guard-result (& guard)))]
      (cond
        [(= code 24) 60]
        [(not (= code 0)) (+ 61 code)]
        [else (release-status (&mut guard) 90)]))))

;; Take the shared lock and exit without releasing it: the kernel releases it
;; with the process.
(define (run-die [root : (& root rooted.FsLinuxRootedDirectory)]) : i64
  (with
    ([guard (acquire root "shared-lock") rooted.cleanup-linux-rooted-guard])
    (if (rooted.linux-rooted-guard-locked? (& guard))
      (io.platform-exit 42)
      70)))

(define fault-root-path : String
  "")

;; Acquire `component` with one injected fault; check the acquisition and
;; close outcomes.
(define (fault-acquire
  [component : String]
  [kind : i64]
  [call : i64]
  [errno-code : i64]
  [result : i64]
  [close : i64]) : bool
  (with
    ([root
        (rooted.linux-rooted-open-root
          (& fault-root-path)
          rooted.linux-rooted-never-cancelled)
        rooted.cleanup-linux-rooted-directory])
    (begin
      (rooted.linux-rooted-test-reset!)
      (rooted.linux-rooted-test-fail-on! kind call errno-code)
      (with
        ([guard
            (acquire (& root) (& component))
            rooted.cleanup-linux-rooted-guard])
        (let
          [ok : bool
            (and
              (=
                (result-code (rooted.linux-rooted-guard-result (& guard)))
                result)
              (=
                (result-code (rooted.linux-rooted-guard-close-result (& guard)))
                close)
              (not (rooted.linux-rooted-guard-locked? (& guard))))]
          (begin
            (rooted.linux-rooted-test-reset!)
            ok))))))

;; An operation failure and a cleanup failure in one acquisition: the
;; sidecar is already locked by another guard of this process, and the close
;; of the losing descriptor fails. Both are reported.
(define (fault-conflict-and-close?) : bool
  (with
    ([root
        (rooted.linux-rooted-open-root
          (& fault-root-path)
          rooted.linux-rooted-never-cancelled)
        rooted.cleanup-linux-rooted-directory])
    (with
      ([holder
          (acquire (& root) "fault-lock")
          rooted.cleanup-linux-rooted-guard])
      (begin
        (rooted.linux-rooted-test-reset!)
        (rooted.linux-rooted-test-fail-on!
          rooted.fs-linux-rooted-syscall-kind-close
          1
          5)
        (with
          ([loser
              (acquire (& root) "fault-lock")
              rooted.cleanup-linux-rooted-guard])
          (let
            [ok : bool
              (and
                (rooted.linux-rooted-guard-locked? (& holder))
                (=
                  (result-code (rooted.linux-rooted-guard-result (& loser)))
                  24)
                (=
                  (result-code
                    (rooted.linux-rooted-guard-close-result (& loser)))
                  13))]
            (begin
              (rooted.linux-rooted-test-reset!)
              ok)))))))

;; Acquire `component`, then release it with one injected fault.
(define (fault-release
  [component : String]
  [kind : i64]
  [errno-code : i64]
  [unlock : i64]
  [close : i64]) : bool
  (with
    ([root
        (rooted.linux-rooted-open-root
          (& fault-root-path)
          rooted.linux-rooted-never-cancelled)
        rooted.cleanup-linux-rooted-directory])
    (with
      ([guard
          (acquire (& root) (& component))
          rooted.cleanup-linux-rooted-guard])
      (begin
        (rooted.linux-rooted-test-reset!)
        (rooted.linux-rooted-test-fail-on! kind 1 errno-code)
        (let
          [ok : bool
            (and
              (rooted.linux-rooted-guard-locked? (& guard))
              (release-is?
                (rooted.linux-rooted-guard-release! (&mut guard))
                unlock
                close)
              (not (rooted.linux-rooted-guard-locked? (& guard))))]
          (begin
            (rooted.linux-rooted-test-reset!)
            ok))))))

;; Acquire `component`, then revalidate it with one injected fault.
(define (fault-revalidate
  [component : String]
  [kind : i64]
  [errno-code : i64]
  [operation : i64]
  [close : i64]) : bool
  (with
    ([root
        (rooted.linux-rooted-open-root
          (& fault-root-path)
          rooted.linux-rooted-never-cancelled)
        rooted.cleanup-linux-rooted-directory])
    (with
      ([guard
          (acquire (& root) (& component))
          rooted.cleanup-linux-rooted-guard])
      (begin
        (rooted.linux-rooted-test-reset!)
        (rooted.linux-rooted-test-fail-on! kind 1 errno-code)
        (let
          [ok : bool
            (finish-is?
              (rooted.linux-rooted-guard-revalidate
                (& root)
                (& component)
                (& guard)
                rooted.linux-rooted-never-cancelled)
              operation
              close)]
          (begin
            (rooted.linux-rooted-test-reset!)
            ok))))))

(define (run-faults) : i64
  (cond
    ;; The sidecar open fails before any descriptor exists.
    [(not
        (fault-acquire
          "fault-lock"
          rooted.fs-linux-rooted-syscall-kind-guard-open
          1
          13
          6
          14))
      80]
    ;; The sidecar fstat fails; the opened descriptor is closed once.
    [(not
        (fault-acquire
          "fault-lock"
          rooted.fs-linux-rooted-syscall-kind-fstat
          1
          5
          8
          0))
      81]
    [(not
        (fault-acquire
          "fault-lock"
          rooted.fs-linux-rooted-syscall-kind-flock
          1
          11
          24
          0))
      82]
    [(not
        (fault-acquire
          "fault-lock"
          rooted.fs-linux-rooted-syscall-kind-flock
          1
          37
          7
          0))
      83]
    [(not
        (fault-acquire
          "fault-lock"
          rooted.fs-linux-rooted-syscall-kind-flock
          1
          4
          9
          0))
      84]
    [(not
        (fault-acquire
          "fault-lock"
          rooted.fs-linux-rooted-syscall-kind-flock
          1
          5
          8
          0))
      85]
    [(not (fault-conflict-and-close?)) 86]
    [(not
        (fault-release
          "fault-lock"
          rooted.fs-linux-rooted-syscall-kind-unlock
          5
          8
          0))
      87]
    [(not
        (fault-release
          "fault-lock"
          rooted.fs-linux-rooted-syscall-kind-close
          5
          0
          13))
      88]
    [(not
        (fault-revalidate
          "fault-lock"
          rooted.fs-linux-rooted-syscall-kind-reopen
          13
          6
          14))
      89]
    [(not
        (fault-revalidate
          "fault-lock"
          rooted.fs-linux-rooted-syscall-kind-fstat
          5
          8
          0))
      90]
    [(not
        (fault-revalidate
          "fault-lock"
          rooted.fs-linux-rooted-syscall-kind-close
          5
          0
          13))
      91]
    [else 0]))

(define (main) : i64
  (if (< (io.arg-count) 3)
    2
    (let
      [mode : String (io.arg 1)]
      [root-path : String (io.arg 2)]
      (begin
        (set! fault-root-path (io.arg 2))
        (with
          ([root
              (rooted.linux-rooted-open-root
                (& root-path)
                rooted.linux-rooted-never-cancelled)
              rooted.cleanup-linux-rooted-directory])
          (if (not (rooted.linux-rooted-directory-open? (& root)))
            3
            (let
              [status : i64
                (cond
                  [(string.eq (& mode) "guard") (run-guard (& root))]
                  [(string.eq (& mode) "hold") (run-hold (& root))]
                  [(string.eq (& mode) "try") (run-try (& root))]
                  [(string.eq (& mode) "die") (run-die (& root))]
                  [(string.eq (& mode) "faults") (run-faults)]
                  [else 4])]
              (if (= status 0)
                42
                status))))))))