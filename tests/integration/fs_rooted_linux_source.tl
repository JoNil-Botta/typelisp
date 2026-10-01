;; Native contract coverage for rooted Linux source snapshots, revalidation and
;; permission-preserving stage finish (#7559). scripts/verify-fs-rooted-linux.sh
;; prepares each mode's tree and checks the bytes and modes left behind.
(import stdlib.byte_buf)
(import stdlib.fs_rooted_linux as rooted)
(import stdlib.io)
(import stdlib.string)

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

(define (cancel-now) : bool
  true)

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

(define (snapshot-of
  [directory : (& directory rooted.FsLinuxRootedDirectory)]
  [component : String]) : rooted.FsLinuxRootedSourceSnapshot
  (with
    ([reader
        (rooted.linux-rooted-reopen-file
          directory
          (& component)
          rooted.linux-rooted-never-cancelled)
        rooted.cleanup-linux-rooted-read-file])
    (if (rooted.linux-rooted-read-file-open? (& reader))
      (rooted.linux-rooted-read-file-source-snapshot
        (& reader)
        rooted.linux-rooted-never-cancelled)
      (rooted.linux-rooted-failed-source-snapshot
        (rooted.linux-rooted-read-file-result (& reader))))))

(define (revalidate
  [directory : (& directory rooted.FsLinuxRootedDirectory)]
  [component : String]
  [source : (& source rooted.FsLinuxRootedSourceSnapshot)]) : rooted.FsLinuxRootedFinishResult
  (rooted.linux-rooted-source-revalidate
    directory
    (& component)
    source
    rooted.linux-rooted-never-cancelled))

;; Finish a new stage named `component` as the replacement for `source`.
(define (finish-stage
  [directory : (& directory rooted.FsLinuxRootedDirectory)]
  [component : String]
  [contents : String]
  [source : (& source rooted.FsLinuxRootedSourceSnapshot)]) : rooted.FsLinuxRootedFinishResult
  (with
    ([stage
        (rooted.linux-rooted-create-file
          directory
          (& component)
          rooted.linux-rooted-never-cancelled)
        rooted.cleanup-linux-rooted-file])
    (if (not (rooted.linux-rooted-file-open? (& stage)))
      (rooted.FsLinuxRootedFinishResult
        (rooted.linux-rooted-file-result (& stage))
        rooted.LinuxRootedClosed)
      (rooted.linux-rooted-file-finish-with-source-permissions!
        (&mut stage)
        (byte_buf.str-as-bytes (& contents))
        (string-length (& contents))
        source
        true
        rooted.linux-rooted-never-cancelled))))

;; The harness creates `source.txt` (15 bytes, 0640) with the hard link
;; `alias.txt`, `other.txt`, `setuid-other.txt` (04644), the directory `dir`,
;; the FIFO `fifo`, the symlink `link`, `victim.txt`, the symlink
;; `victim-link`, and
;; `sub/inner.txt`.
(define (check-identity [root : (& root rooted.FsLinuxRootedDirectory)]) : i64
  (let
    [source : rooted.FsLinuxRootedSourceSnapshot
      (snapshot-of root "source.txt")]
    [alias : rooted.FsLinuxRootedSourceSnapshot (snapshot-of root "alias.txt")]
    [fifo : rooted.FsLinuxRootedSourceSnapshot (snapshot-of root "fifo")]
    (cond
      [(not (= (result-code (rooted.linux-rooted-source-result (& source))) 0))
        10]
      [(not (= (rooted.linux-rooted-source-permissions (& source)) 416)) 11]
      [(not (= (rooted.linux-rooted-source-links (& source)) (cast 2 : u64)))
        12]
      [(not (= (rooted.linux-rooted-source-length (& source)) 15)) 13]
      [(not (rooted.linux-rooted-source-same-file? (& source) (& alias))) 14]
      [(not (finish-is? (revalidate root "source.txt" (& source)) 0 0)) 15]
      [(not (finish-is? (revalidate root "alias.txt" (& source)) 0 0)) 16]
      [(not (finish-is? (revalidate root "other.txt" (& source)) 20 0)) 17]
      [(not (finish-is? (revalidate root "dir" (& source)) 5 0)) 18]
      [(not (finish-is? (revalidate root "fifo" (& source)) 5 0)) 19]
      [(not (finish-is? (revalidate root "link" (& source)) 4 14)) 20]
      [(not (finish-is? (revalidate root "missing.txt" (& source)) 2 14)) 21]
      [(not (finish-is? (revalidate root "a/b" (& source)) 1 14)) 22]
      [(not (= (result-code (rooted.linux-rooted-source-result (& fifo))) 5))
        23]
      [(not
          (finish-is?
            (rooted.linux-rooted-source-revalidate
              root
              "source.txt"
              (& source)
              cancel-now)
            9
            14))
        24]
      [else 0])))

;; Replacing the final name changes its identity; the remaining hard link
;; still names the original file, which lost a link.
(define (check-replacement [root : (& root rooted.FsLinuxRootedDirectory)]) : i64
  (let
    [source : rooted.FsLinuxRootedSourceSnapshot
      (snapshot-of root "source.txt")]
    (cond
      [(not
          (rooted.linux-rooted-result-ok?
            (create-text root "replacement.txt" "replacement")))
        30]
      [(not
          (rooted.linux-rooted-result-ok?
            (rooted.linux-rooted-rename-replace
              root
              "replacement.txt"
              root
              "source.txt"
              rooted.linux-rooted-never-cancelled)))
        31]
      [(not (finish-is? (revalidate root "source.txt" (& source)) 20 0)) 32]
      [(not (finish-is? (revalidate root "alias.txt" (& source)) 21 0)) 33]
      [else 0])))

;; A retained child directory keeps revalidating after its parent entry is
;; renamed; no process-relative path is involved.
(define (check-parent-rename [root : (& root rooted.FsLinuxRootedDirectory)]) : i64
  (with
    ([sub
        (rooted.linux-rooted-reopen-directory
          root
          "sub"
          rooted.linux-rooted-never-cancelled)
        rooted.cleanup-linux-rooted-directory])
    (if (not (rooted.linux-rooted-directory-open? (& sub)))
      40
      (let
        [inner : rooted.FsLinuxRootedSourceSnapshot
          (snapshot-of (& sub) "inner.txt")]
        (cond
          [(not
              (rooted.linux-rooted-result-ok?
                (rooted.linux-rooted-source-result (& inner))))
            41]
          [(not
              (rooted.linux-rooted-result-ok?
                (rooted.linux-rooted-rename-no-replace
                  root
                  "sub"
                  root
                  "sub-moved"
                  rooted.linux-rooted-never-cancelled)))
            42]
          [(not (finish-is? (revalidate (& sub) "inner.txt" (& inner)) 0 0)) 43]
          [else 0])))))

;; A symlink moved over an admitted name is rejected, not followed.
(define (check-symlink-substitution
  [root : (& root rooted.FsLinuxRootedDirectory)]) : i64
  (let
    [victim : rooted.FsLinuxRootedSourceSnapshot
      (snapshot-of root "victim.txt")]
    (cond
      [(not
          (rooted.linux-rooted-result-ok?
            (rooted.linux-rooted-source-result (& victim))))
        50]
      [(not
          (rooted.linux-rooted-result-ok?
            (rooted.linux-rooted-rename-replace
              root
              "victim-link"
              root
              "victim.txt"
              rooted.linux-rooted-never-cancelled)))
        51]
      [(not (finish-is? (revalidate root "victim.txt" (& victim)) 4 14)) 52]
      [else 0])))

;; Another file carrying a special bit is a changed identity, not a changed
;; source. A source whose mode drops to 0000 after admission is still compared
;; by metadata, because revalidation only names the file.
(define (check-special-and-sealed
  [root : (& root rooted.FsLinuxRootedDirectory)]) : i64
  (with
    ([stage
        (rooted.linux-rooted-create-file
          root
          "sealed.txt"
          rooted.linux-rooted-never-cancelled)
        rooted.cleanup-linux-rooted-file])
    (if (not (rooted.linux-rooted-file-open? (& stage)))
      25
      (let
        [source : rooted.FsLinuxRootedSourceSnapshot
          (snapshot-of root "source.txt")]
        [sealed : rooted.FsLinuxRootedSourceSnapshot
          (snapshot-of root "sealed.txt")]
        [empty : String ""]
        [no-access : rooted.FsLinuxRootedSourceSnapshot
          (forged (& sealed) (cast 0 : u32) 0)]
        [finished : rooted.FsLinuxRootedFinishResult
          (rooted.linux-rooted-file-finish-with-source-permissions!
            (&mut stage)
            (byte_buf.str-as-bytes (& empty))
            0
            (& no-access)
            true
            rooted.linux-rooted-never-cancelled)]
        (cond
          [(not
              (finish-is? (revalidate root "setuid-other.txt" (& source)) 20 0))
            26]
          [(not
              (rooted.linux-rooted-result-ok?
                (rooted.linux-rooted-source-result (& sealed))))
            27]
          [(not (finish-is? finished 0 0)) 28]
          [(not (finish-is? (revalidate root "sealed.txt" (& sealed)) 21 0)) 29]
          [else 0])))))

(define (run-revalidate [root : (& root rooted.FsLinuxRootedDirectory)]) : i64
  (let
    [identity : i64 (check-identity root)]
    [special : i64
      (if (= identity 0)
        (check-special-and-sealed root)
        0)]
    (cond
      [(not (= identity 0)) identity]
      [(not (= special 0)) special]
      [else
        (let
          [replacement : i64 (check-replacement root)]
          (if (not (= replacement 0))
            replacement
            (let
              [parent : i64 (check-parent-rename root)]
              (if (not (= parent 0))
                parent
                (check-symlink-substitution root)))))])))

;; A snapshot whose fields were not produced by an admitted `fstat`.
(define (forged
  [source : (& source rooted.FsLinuxRootedSourceSnapshot)]
  [owner-delta : u32]
  [permissions : i64]) : rooted.FsLinuxRootedSourceSnapshot
  (rooted.FsLinuxRootedSourceSnapshot
    rooted.LinuxRootedOk
    source.device
    source.inode
    source.length
    source.links
    (+ source.owner owner-delta)
    source.group
    permissions))

;; The harness creates `source.txt` (0640) and `setuid.txt` (04644) and checks
;; every stage's bytes and mode afterwards.
(define (run-finish [root : (& root rooted.FsLinuxRootedDirectory)]) : i64
  (let
    [source : rooted.FsLinuxRootedSourceSnapshot
      (snapshot-of root "source.txt")]
    [setuid : rooted.FsLinuxRootedSourceSnapshot
      (snapshot-of root "setuid.txt")]
    [wide : rooted.FsLinuxRootedSourceSnapshot
      (forged (& source) (cast 0 : u32) 512)]
    [negative : rooted.FsLinuxRootedSourceSnapshot
      (forged (& source) (cast 0 : u32) -1)]
    [foreign : rooted.FsLinuxRootedSourceSnapshot
      (forged (& source) (cast 1 : u32) 416)]
    (cond
      [(not
          (rooted.linux-rooted-result-ok?
            (rooted.linux-rooted-source-result (& source))))
        60]
      [(not
          (finish-is?
            (finish-stage root "stage.txt" "rewritten\n" (& source))
            0
            0))
        61]
      [(not (= (result-code (rooted.linux-rooted-source-result (& setuid))) 7))
        62]
      [(not
          (finish-is?
            (finish-stage root "stage-setuid.txt" "never\n" (& setuid))
            22
            0))
        63]
      [(not
          (finish-is?
            (finish-stage root "stage-wide.txt" "never\n" (& wide))
            22
            0))
        64]
      [(not
          (finish-is?
            (finish-stage root "stage-negative.txt" "never\n" (& negative))
            22
            0))
        65]
      [(not
          (finish-is?
            (finish-stage root "stage-foreign.txt" "never\n" (& foreign))
            7
            0))
        66]
      [(not
          (begin
            (rooted.linux-rooted-test-enable-mode-drift!)
            (finish-is?
              (finish-stage root "stage-drift.txt" "drifted\n" (& source))
              23
              0)))
        67]
      [else 0])))

(define fault-root-path : String
  "")

(define (fault-snapshot-fstat?) : bool
  (with
    ([root
        (rooted.linux-rooted-open-root
          (& fault-root-path)
          rooted.linux-rooted-never-cancelled)
        rooted.cleanup-linux-rooted-directory])
    (with
      ([reader
          (rooted.linux-rooted-reopen-file
            (& root)
            "source.txt"
            rooted.linux-rooted-never-cancelled)
          rooted.cleanup-linux-rooted-read-file])
      (begin
        (rooted.linux-rooted-test-reset!)
        (rooted.linux-rooted-test-fail-on!
          rooted.fs-linux-rooted-syscall-kind-fstat
          1
          5)
        (let
          [snapshot : rooted.FsLinuxRootedSourceSnapshot
            (rooted.linux-rooted-read-file-source-snapshot
              (& reader)
              rooted.linux-rooted-never-cancelled)]
          [ok : bool
            (= (result-code (rooted.linux-rooted-source-result (& snapshot))) 8)]
          (begin
            (rooted.linux-rooted-test-reset!)
            ok))))))

(define (fault-revalidate
  [kind : i64]
  [call : i64]
  [errno-code : i64]
  [operation : i64]
  [close : i64]) : bool
  (with
    ([root
        (rooted.linux-rooted-open-root
          (& fault-root-path)
          rooted.linux-rooted-never-cancelled)
        rooted.cleanup-linux-rooted-directory])
    (let
      [source : rooted.FsLinuxRootedSourceSnapshot
        (snapshot-of (& root) "source.txt")]
      (begin
        (rooted.linux-rooted-test-reset!)
        (rooted.linux-rooted-test-fail-on! kind call errno-code)
        (let
          [ok : bool
            (finish-is?
              (revalidate (& root) "source.txt" (& source))
              operation
              close)]
          (begin
            (rooted.linux-rooted-test-reset!)
            ok))))))

;; An operation failure and a cleanup failure in one revalidation: the name
;; denotes another file and the one close fails. Both are reported.
(define (fault-revalidate-identity-and-close?) : bool
  (with
    ([root
        (rooted.linux-rooted-open-root
          (& fault-root-path)
          rooted.linux-rooted-never-cancelled)
        rooted.cleanup-linux-rooted-directory])
    (let
      [source : rooted.FsLinuxRootedSourceSnapshot
        (snapshot-of (& root) "source.txt")]
      (begin
        (rooted.linux-rooted-test-reset!)
        (rooted.linux-rooted-test-fail-on!
          rooted.fs-linux-rooted-syscall-kind-close
          1
          5)
        (let
          [ok : bool
            (finish-is? (revalidate (& root) "other.txt" (& source)) 20 13)]
          (begin
            (rooted.linux-rooted-test-reset!)
            ok))))))

;; A stage finished with a mask that was never admitted, whose close also
;; fails: both outcomes are reported and no byte is written.
(define (fault-finish-invalid-and-close?) : bool
  (with
    ([root
        (rooted.linux-rooted-open-root
          (& fault-root-path)
          rooted.linux-rooted-never-cancelled)
        rooted.cleanup-linux-rooted-directory])
    (let
      [source : rooted.FsLinuxRootedSourceSnapshot
        (snapshot-of (& root) "source.txt")]
      [wide : rooted.FsLinuxRootedSourceSnapshot
        (forged (& source) (cast 0 : u32) 512)]
      [stage : String "stage-invalid-close.txt"]
      (with
        ([file
            (rooted.linux-rooted-create-file
              (& root)
              (& stage)
              rooted.linux-rooted-never-cancelled)
            rooted.cleanup-linux-rooted-file])
        (begin
          (rooted.linux-rooted-test-reset!)
          (rooted.linux-rooted-test-fail-on!
            rooted.fs-linux-rooted-syscall-kind-close
            1
            5)
          (let
            [contents : String "never\n"]
            [ok : bool
              (finish-is?
                (rooted.linux-rooted-file-finish-with-source-permissions!
                  (&mut file)
                  (byte_buf.str-as-bytes (& contents))
                  (string-length (& contents))
                  (& wide)
                  true
                  rooted.linux-rooted-never-cancelled)
                22
                13)]
            (begin
              (rooted.linux-rooted-test-reset!)
              ok)))))))

(define (fault-finish
  [stage : String]
  [kind : i64]
  [call : i64]
  [errno-code : i64]
  [operation : i64]
  [close : i64]) : bool
  (with
    ([root
        (rooted.linux-rooted-open-root
          (& fault-root-path)
          rooted.linux-rooted-never-cancelled)
        rooted.cleanup-linux-rooted-directory])
    (let
      [source : rooted.FsLinuxRootedSourceSnapshot
        (snapshot-of (& root) "source.txt")]
      (with
        ([file
            (rooted.linux-rooted-create-file
              (& root)
              (& stage)
              rooted.linux-rooted-never-cancelled)
            rooted.cleanup-linux-rooted-file])
        (begin
          (rooted.linux-rooted-test-reset!)
          (rooted.linux-rooted-test-fail-on! kind call errno-code)
          (let
            [contents : String "faulted\n"]
            [ok : bool
              (finish-is?
                (rooted.linux-rooted-file-finish-with-source-permissions!
                  (&mut file)
                  (byte_buf.str-as-bytes (& contents))
                  (string-length (& contents))
                  (& source)
                  true
                  rooted.linux-rooted-never-cancelled)
                operation
                close)]
            (begin
              (rooted.linux-rooted-test-reset!)
              ok)))))))

;; The harness creates `source.txt` (0640) and checks that the stages whose
;; ownership check failed received no bytes.
(define (run-faults) : i64
  (cond
    [(not (fault-snapshot-fstat?)) 70]
    ;; Revalidation reopen: EACCES before any descriptor exists.
    [(not
        (fault-revalidate rooted.fs-linux-rooted-syscall-kind-reopen 1 13 6 14))
      71]
    ;; Revalidation fstat fails; its descriptor still gets its one close.
    [(not (fault-revalidate rooted.fs-linux-rooted-syscall-kind-fstat 1 5 8 0))
      72]
    ;; Revalidation succeeds but its close fails.
    [(not (fault-revalidate rooted.fs-linux-rooted-syscall-kind-close 1 5 0 13))
      73]
    [(not (fault-revalidate-identity-and-close?)) 74]
    [(not (fault-finish-invalid-and-close?)) 80]
    ;; Stage ownership fstat (call 1) fails before any byte is written.
    [(not
        (fault-finish
          "stage-owner-fstat.txt"
          rooted.fs-linux-rooted-syscall-kind-fstat
          1
          5
          8
          0))
      75]
    ;; The checked fchmod fails.
    [(not
        (fault-finish
          "stage-fchmod.txt"
          rooted.fs-linux-rooted-syscall-kind-fchmod
          1
          1
          11
          0))
      76]
    ;; The verification fstat (call 2) fails after the mode was applied.
    [(not
        (fault-finish
          "stage-verify-fstat.txt"
          rooted.fs-linux-rooted-syscall-kind-fstat
          2
          5
          8
          0))
      77]
    ;; Flush fails after a verified mode.
    [(not
        (fault-finish
          "stage-fsync.txt"
          rooted.fs-linux-rooted-syscall-kind-fsync
          1
          5
          12
          0))
      78]
    ;; Every step succeeds but the stage's close fails.
    [(not
        (fault-finish
          "stage-close.txt"
          rooted.fs-linux-rooted-syscall-kind-close
          1
          5
          0
          13))
      79]
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
                  [(string.eq (& mode) "revalidate") (run-revalidate (& root))]
                  [(string.eq (& mode) "finish") (run-finish (& root))]
                  [(string.eq (& mode) "faults") (run-faults)]
                  [else 4])]
              (if (= status 0)
                42
                status))))))))