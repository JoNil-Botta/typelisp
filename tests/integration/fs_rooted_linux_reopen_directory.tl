;; Linux native coverage for reopening one verified child-directory capability.
;; The shell gate supplies adversarial entries and checks retained filesystem
;; effects; this fixture owns result, fault, cancellation, and close assertions.
(import stdlib.byte_buf)
(import stdlib.fs)
(import stdlib.fs_rooted_linux as rooted)
(import stdlib.io)
(import stdlib.string)

(define cancel-calls : i64
  0)

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
    [(rooted.LinuxRootedReadFailure) 19]))

(define (cancel-now) : bool
  true)

(define (cancel-on-second) : bool
  (begin
    (set! cancel-calls (+ cancel-calls 1))
    (>= cancel-calls 2)))

(define (write-text
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

(define (read-text
  [directory : (& directory rooted.FsLinuxRootedDirectory)]
  [component : String]
  [expected : String]) : i64
  (with
    ([reader
        (rooted.linux-rooted-reopen-file
          directory
          (& component)
          rooted.linux-rooted-never-cancelled)
        rooted.cleanup-linux-rooted-read-file])
    (begin
      (unless
        (rooted.linux-rooted-read-file-open? (& reader))
        (return
          (+
            100
            (result-code (rooted.linux-rooted-read-file-result (& reader))))))
      (let
        [metadata : rooted.FsLinuxRootedFileMetadata
          (rooted.linux-rooted-read-file-metadata
            (& reader)
            rooted.linux-rooted-never-cancelled)]
        [expected-length : i64 (string-length (& expected))]
        (begin
          (when
            (or
              (not
                (rooted.linux-rooted-result-ok?
                  (rooted.linux-rooted-metadata-result metadata)))
              (not
                (=
                  (rooted.linux-rooted-metadata-length metadata)
                  expected-length)))
            (return 201))
          (let
            [read : rooted.FsLinuxRootedReadResult
              (rooted.linux-rooted-read-file-chunk!
                (&mut reader)
                expected-length
                rooted.linux-rooted-never-cancelled)]
            [operation : rooted.FsLinuxRootedResult
              (rooted.linux-rooted-read-operation (& read))]
            [eof : bool (rooted.linux-rooted-read-eof? (& read))]
            [short : bool (rooted.linux-rooted-read-short? (& read))]
            [actual : String
              (byte_buf.to-string (rooted.linux-rooted-read-bytes read))]
            [close-result : rooted.FsLinuxRootedResult
              (rooted.linux-rooted-read-file-close! (&mut reader))]
            (if (and
              (rooted.linux-rooted-result-ok? operation)
              (not eof)
              (not short)
              (string.eq (& actual) (& expected))
              (rooted.linux-rooted-result-ok? close-result))
              0
              202)))))))

(define (scenario-retained
  [root-path : (& root-path str)]
  [moved-root-path : (& moved-root-path str)]) : i64
  (with
    ([root
        (rooted.linux-rooted-open-root
          root-path
          rooted.linux-rooted-never-cancelled)
        rooted.cleanup-linux-rooted-directory])
    (begin
      (unless (rooted.linux-rooted-directory-open? (& root)) (return 10))
      (unless
        (io.result-unit-ok? (fs.try-rename root-path moved-root-path))
        (return 11))
      (rooted.linux-rooted-test-reset!)
      (with
        ([generation
            (rooted.linux-rooted-reopen-directory
              (& root)
              "generation"
              rooted.linux-rooted-never-cancelled)
            rooted.cleanup-linux-rooted-directory])
        (begin
          (unless
            (rooted.linux-rooted-directory-open? (& generation))
            (return
              (+
                20
                (result-code
                  (rooted.linux-rooted-directory-result (& generation))))))
          (unless
            (and
              (=
                (rooted.linux-rooted-test-call-count
                  rooted.fs-linux-rooted-syscall-kind-reopen-directory)
                1)
              (=
                (rooted.linux-rooted-test-call-count
                  rooted.fs-linux-rooted-syscall-kind-openat2)
                0)
              (=
                (rooted.linux-rooted-test-call-count
                  rooted.fs-linux-rooted-syscall-kind-fstat)
                1)
              (=
                (rooted.linux-rooted-test-call-count
                  rooted.fs-linux-rooted-syscall-kind-fchmod)
                0))
            (return 12))
          (let
            [expected : String "original generation\n"]
            (unless
              (= (read-text (& generation) "payload.txt" expected) 0)
              (return 13)))
          (let
            [old-child : String (fs.path-join moved-root-path "generation")]
            [moved-child : String
              (fs.path-join moved-root-path "generation-moved")]
            (unless
              (io.result-unit-ok? (fs.try-rename (& old-child) (& moved-child)))
              (return 14)))
          (with
            ([replacement
                (rooted.linux-rooted-create-directory
                  (& root)
                  "generation"
                  rooted.linux-rooted-never-cancelled)
                rooted.cleanup-linux-rooted-directory])
            (begin
              (unless
                (rooted.linux-rooted-directory-open? (& replacement))
                (return 15))
              (unless
                (rooted.linux-rooted-result-ok?
                  (write-text
                    (& replacement)
                    "payload.txt"
                    "replacement generation\n"))
                (return 16))))
          (let
            [expected : String "original generation\n"]
            (unless
              (= (read-text (& generation) "payload.txt" expected) 0)
              (return 17)))
          42)))))

(define (scenario-renamed-before [root-path : (& root-path str)]) : i64
  (with
    ([root
        (rooted.linux-rooted-open-root
          root-path
          rooted.linux-rooted-never-cancelled)
        rooted.cleanup-linux-rooted-directory])
    (begin
      (unless (rooted.linux-rooted-directory-open? (& root)) (return 10))
      (with
        ([generation
            (rooted.linux-rooted-reopen-directory
              (& root)
              "generation"
              rooted.linux-rooted-never-cancelled)
            rooted.cleanup-linux-rooted-directory])
        (begin
          (unless
            (rooted.linux-rooted-directory-open? (& generation))
            (return
              (+
                20
                (result-code
                  (rooted.linux-rooted-directory-result (& generation))))))
          (let
            [expected : String "replacement before acquisition\n"]
            (if (= (read-text (& generation) "payload.txt" expected) 0)
              42
              30)))))))

(define (scenario-classify
  [root-path : (& root-path str)]
  [component : String]
  [expected : i64]) : i64
  (with
    ([root
        (rooted.linux-rooted-open-root
          root-path
          rooted.linux-rooted-never-cancelled)
        rooted.cleanup-linux-rooted-directory])
    (begin
      (unless (rooted.linux-rooted-directory-open? (& root)) (return 10))
      (rooted.linux-rooted-test-reset!)
      (with
        ([child
            (rooted.linux-rooted-reopen-directory
              (& root)
              (& component)
              rooted.linux-rooted-never-cancelled)
            rooted.cleanup-linux-rooted-directory])
        (let
          [actual : i64
            (result-code (rooted.linux-rooted-directory-result (& child)))]
          [status : i64 42]
          (begin
            (when (not (= actual expected)) (set! status (+ 100 actual)))
            (when
              (and
                (= status 42)
                (rooted.linux-rooted-directory-open? (& child)))
              (set! status 80))
            (when
              (and
                (= status 42)
                (not
                  (=
                    (rooted.linux-rooted-test-call-count
                      rooted.fs-linux-rooted-syscall-kind-reopen-directory)
                    1)))
              (set! status 81))
            (when
              (and
                (= status 42)
                (not
                  (=
                    (rooted.linux-rooted-test-call-count
                      rooted.fs-linux-rooted-syscall-kind-openat2)
                    0)))
              (set! status 82))
            (when
              (and
                (= status 42)
                (not
                  (=
                    (rooted.linux-rooted-test-call-count
                      rooted.fs-linux-rooted-syscall-kind-fchmod)
                    0)))
              (set! status 83))
            status))))))

(define (fault-pre-open [root : (& root rooted.FsLinuxRootedDirectory)]) : i64
  (begin
    (rooted.linux-rooted-test-reset!)
    (with
      ([invalid
          (rooted.linux-rooted-reopen-directory
            root
            "../escape"
            rooted.linux-rooted-never-cancelled)
          rooted.cleanup-linux-rooted-directory])
      (unless
        (and
          (= (result-code (rooted.linux-rooted-directory-result (& invalid))) 1)
          (=
            (rooted.linux-rooted-test-call-count
              rooted.fs-linux-rooted-syscall-kind-reopen-directory)
            0))
        (return 1)))
    (rooted.linux-rooted-test-reset!)
    (with
      ([cancelled
          (rooted.linux-rooted-reopen-directory root "generation" cancel-now)
          rooted.cleanup-linux-rooted-directory])
      (if (and
        (= (result-code (rooted.linux-rooted-directory-result (& cancelled))) 9)
        (=
          (rooted.linux-rooted-test-call-count
            rooted.fs-linux-rooted-syscall-kind-reopen-directory)
          0)
        (=
          (rooted.linux-rooted-test-call-count
            rooted.fs-linux-rooted-syscall-kind-fstat)
          0)
        (=
          (rooted.linux-rooted-test-call-count
            rooted.fs-linux-rooted-syscall-kind-close)
          0))
        0
        2))))

(define (fault-openat2 [root : (& root rooted.FsLinuxRootedDirectory)]) : i64
  (begin
    (rooted.linux-rooted-test-reset!)
    (rooted.linux-rooted-test-fail-on!
      rooted.fs-linux-rooted-syscall-kind-reopen-directory
      1
      38)
    (with
      ([child
          (rooted.linux-rooted-reopen-directory
            root
            "generation"
            rooted.linux-rooted-never-cancelled)
          rooted.cleanup-linux-rooted-directory])
      (if (and
        (= (result-code (rooted.linux-rooted-directory-result (& child))) 7)
        (=
          (rooted.linux-rooted-test-call-count
            rooted.fs-linux-rooted-syscall-kind-reopen-directory)
          1)
        (=
          (rooted.linux-rooted-test-call-count
            rooted.fs-linux-rooted-syscall-kind-openat2)
          0)
        (=
          (rooted.linux-rooted-test-call-count
            rooted.fs-linux-rooted-syscall-kind-fstat)
          0)
        (=
          (rooted.linux-rooted-test-call-count
            rooted.fs-linux-rooted-syscall-kind-close)
          0))
        0
        3))))

(define (fault-post-open [root : (& root rooted.FsLinuxRootedDirectory)]) : i64
  (begin
    (rooted.linux-rooted-test-reset!)
    (rooted.linux-rooted-test-fail-on!
      rooted.fs-linux-rooted-syscall-kind-fstat
      1
      5)
    (with
      ([child
          (rooted.linux-rooted-reopen-directory
            root
            "generation"
            rooted.linux-rooted-never-cancelled)
          rooted.cleanup-linux-rooted-directory])
      (if (and
        (= (result-code (rooted.linux-rooted-directory-result (& child))) 8)
        (=
          (result-code (rooted.linux-rooted-directory-close-result (& child)))
          0)
        (=
          (rooted.linux-rooted-test-call-count
            rooted.fs-linux-rooted-syscall-kind-reopen-directory)
          1)
        (=
          (rooted.linux-rooted-test-call-count
            rooted.fs-linux-rooted-syscall-kind-fstat)
          1)
        (=
          (rooted.linux-rooted-test-call-count
            rooted.fs-linux-rooted-syscall-kind-close)
          1))
        0
        4))))

(define (fault-cancel-after-open
  [root : (& root rooted.FsLinuxRootedDirectory)]) : i64
  (begin
    (rooted.linux-rooted-test-reset!)
    (set! cancel-calls 0)
    (with
      ([child
          (rooted.linux-rooted-reopen-directory
            root
            "generation"
            cancel-on-second)
          rooted.cleanup-linux-rooted-directory])
      (if (and
        (= (result-code (rooted.linux-rooted-directory-result (& child))) 9)
        (=
          (result-code (rooted.linux-rooted-directory-close-result (& child)))
          0)
        (=
          (rooted.linux-rooted-test-call-count
            rooted.fs-linux-rooted-syscall-kind-reopen-directory)
          1)
        (=
          (rooted.linux-rooted-test-call-count
            rooted.fs-linux-rooted-syscall-kind-fstat)
          0)
        (=
          (rooted.linux-rooted-test-call-count
            rooted.fs-linux-rooted-syscall-kind-close)
          1))
        0
        5))))

(define (fault-operation-and-close
  [root : (& root rooted.FsLinuxRootedDirectory)]) : i64
  (begin
    (rooted.linux-rooted-test-reset!)
    (set! cancel-calls 0)
    (rooted.linux-rooted-test-fail-on!
      rooted.fs-linux-rooted-syscall-kind-close
      1
      5)
    (with
      ([child
          (rooted.linux-rooted-reopen-directory
            root
            "generation"
            cancel-on-second)
          rooted.cleanup-linux-rooted-directory])
      (if (and
        (= (result-code (rooted.linux-rooted-directory-result (& child))) 9)
        (=
          (result-code (rooted.linux-rooted-directory-close-result (& child)))
          13)
        (=
          (rooted.linux-rooted-test-call-count
            rooted.fs-linux-rooted-syscall-kind-close)
          1))
        0
        6))))

(define (fault-mapped-openat2
  [root : (& root rooted.FsLinuxRootedDirectory)]
  [errno-code : i64]
  [expected : i64]) : i64
  (begin
    (rooted.linux-rooted-test-reset!)
    (rooted.linux-rooted-test-fail-on!
      rooted.fs-linux-rooted-syscall-kind-reopen-directory
      1
      errno-code)
    (with
      ([child
          (rooted.linux-rooted-reopen-directory
            root
            "generation"
            rooted.linux-rooted-never-cancelled)
          rooted.cleanup-linux-rooted-directory])
      (if (and
        (=
          (result-code (rooted.linux-rooted-directory-result (& child)))
          expected)
        (=
          (rooted.linux-rooted-test-call-count
            rooted.fs-linux-rooted-syscall-kind-reopen-directory)
          1)
        (=
          (rooted.linux-rooted-test-call-count
            rooted.fs-linux-rooted-syscall-kind-close)
          0))
        0
        7))))

(define (scenario-faults [root-path : (& root-path str)]) : i64
  (with
    ([root
        (rooted.linux-rooted-open-root
          root-path
          rooted.linux-rooted-never-cancelled)
        rooted.cleanup-linux-rooted-directory])
    (begin
      (unless (rooted.linux-rooted-directory-open? (& root)) (return 10))
      (let
        [status : i64 (fault-pre-open (& root))]
        (begin
          (when (= status 0) (set! status (fault-openat2 (& root))))
          (when (= status 0) (set! status (fault-post-open (& root))))
          (when (= status 0) (set! status (fault-cancel-after-open (& root))))
          (when (= status 0) (set! status (fault-operation-and-close (& root))))
          (when (= status 0) (set! status (fault-mapped-openat2 (& root) 13 6)))
          (when (= status 0) (set! status (fault-mapped-openat2 (& root) 11 4)))
          (when (= status 0) (set! status (fault-mapped-openat2 (& root) 40 4)))
          (when (= status 0) (set! status (fault-mapped-openat2 (& root) 18 4)))
          (rooted.linux-rooted-test-reset!)
          (unless (= status 0) (return (+ 100 status)))
          (let
            [closed : rooted.FsLinuxRootedResult
              (rooted.linux-rooted-directory-close! (&mut root))]
            (unless (rooted.linux-rooted-result-ok? closed) (return 18)))
          (rooted.linux-rooted-test-reset!)
          (with
            ([child
                (rooted.linux-rooted-reopen-directory
                  (& root)
                  "generation"
                  rooted.linux-rooted-never-cancelled)
                rooted.cleanup-linux-rooted-directory])
            (if (and
              (=
                (result-code (rooted.linux-rooted-directory-result (& child)))
                14)
              (=
                (rooted.linux-rooted-test-call-count
                  rooted.fs-linux-rooted-syscall-kind-reopen-directory)
                0))
              42
              19)))))))

(define (main) : i64
  (if (< (io.arg-count) 3)
    2
    (let
      [scenario : String (io.arg 1)]
      [root-path : String (io.arg 2)]
      (cond
        [(string.eq (& scenario) "retained")
          (if (< (io.arg-count) 4)
            3
            (let
              [moved-root-path : String (io.arg 3)]
              (scenario-retained (& root-path) (& moved-root-path))))]
        [(string.eq (& scenario) "renamed-before")
          (scenario-renamed-before (& root-path))]
        [(string.eq (& scenario) "missing")
          (scenario-classify (& root-path) "missing" 2)]
        [(string.eq (& scenario) "file")
          (scenario-classify (& root-path) "ordinary" 5)]
        [(string.eq (& scenario) "special")
          (scenario-classify (& root-path) "special" 5)]
        [(string.eq (& scenario) "symlink")
          (scenario-classify (& root-path) "symlink" 5)]
        [(string.eq (& scenario) "mount")
          (scenario-classify (& root-path) "mounted" 4)]
        [(string.eq (& scenario) "faults") (scenario-faults (& root-path))]
        [else 4]))))