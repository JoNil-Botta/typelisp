;; Linux native coverage for the private rooted exclusive-create backend.
;; The shell gate supplies isolated root paths and checks filesystem effects;
;; this fixture owns retained-descriptor, result, retry, and cleanup assertions.
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

(define (finish-code [result : rooted.FsLinuxRootedFinishResult]) : i64
  (+
    (* 100 (result-code (rooted.linux-rooted-finish-operation result)))
    (result-code (rooted.linux-rooted-finish-close result))))

(define (finish-text!
  [file : (&mut file rooted.FsLinuxRootedFile)]
  [contents : (& contents str)]
  [flush : bool]) : rooted.FsLinuxRootedFinishResult
  (rooted.linux-rooted-file-finish!
    file
    (byte_buf.str-as-bytes contents)
    (string-length contents)
    rooted.LinuxRootedRegularFile
    flush
    rooted.linux-rooted-never-cancelled))

(define (finish-text-with-cancel!
  [file : (&mut file rooted.FsLinuxRootedFile)]
  [contents : (& contents str)]
  [cancel-check : (-> bool)]) : rooted.FsLinuxRootedFinishResult
  (rooted.linux-rooted-file-finish!
    file
    (byte_buf.str-as-bytes contents)
    (string-length contents)
    rooted.LinuxRootedRegularFile
    false
    cancel-check))

(define (finish-text-mode!
  [file : (&mut file rooted.FsLinuxRootedFile)]
  [contents : (& contents str)]
  [mode : rooted.FsLinuxRootedFileMode]) : rooted.FsLinuxRootedFinishResult
  (rooted.linux-rooted-file-finish!
    file
    (byte_buf.str-as-bytes contents)
    (string-length contents)
    mode
    false
    rooted.linux-rooted-never-cancelled))

(define (cancel-on-second) : bool
  (begin
    (set! cancel-calls (+ cancel-calls 1))
    (>= cancel-calls 2)))

(define (cancel-now) : bool
  true)

(define (scenario-happy [root-path : (& root-path str)]) : i64
  (let
    [status : i64 10]
    (begin
      (with
        ([root-dir
            (rooted.linux-rooted-open-root
              root-path
              rooted.linux-rooted-never-cancelled)
            rooted.cleanup-linux-rooted-directory])
        (begin
          (if (rooted.linux-rooted-directory-open? (& root-dir))
            (with
              ([child
                  (rooted.linux-rooted-create-directory
                    (& root-dir)
                    "tree"
                    rooted.linux-rooted-never-cancelled)
                  rooted.cleanup-linux-rooted-directory])
              (begin
                (if (rooted.linux-rooted-directory-open? (& child))
                  (begin
                    (with
                      ([file
                          (rooted.linux-rooted-create-file
                            (& child)
                            "payload.txt"
                            rooted.linux-rooted-never-cancelled)
                          rooted.cleanup-linux-rooted-file])
                      (begin
                        (if (rooted.linux-rooted-file-open? (& file))
                          (let
                            [contents : String "rooted payload\n"]
                            [finished : rooted.FsLinuxRootedFinishResult
                              (finish-text! (&mut file) (& contents) true)]
                            (set!
                              status
                              (if (rooted.linux-rooted-finish-ok? finished)
                                42
                                (+ 60 (finish-code finished)))))
                          (set!
                            status
                            (+
                              40
                              (result-code
                                (rooted.linux-rooted-file-result (& file))))))
                        unit))
                    (if (= status 42)
                      (with
                        ([executable
                            (rooted.linux-rooted-create-file
                              (& child)
                              "run.sh"
                              rooted.linux-rooted-never-cancelled)
                            rooted.cleanup-linux-rooted-file])
                        (begin
                          (if (rooted.linux-rooted-file-open? (& executable))
                            (let
                              [contents : String "#!/bin/sh\nexit 0\n"]
                              [finished : rooted.FsLinuxRootedFinishResult
                                (finish-text-mode!
                                  (&mut executable)
                                  (& contents)
                                  rooted.LinuxRootedExecutableFile)]
                              (if (rooted.linux-rooted-finish-ok? finished)
                                unit
                                (set! status (+ 80 (finish-code finished)))))
                            (set!
                              status
                              (+
                                70
                                (result-code
                                  (rooted.linux-rooted-file-result
                                    (& executable))))))
                          unit))
                      unit)
                    unit)
                  (set!
                    status
                    (+
                      20
                      (result-code
                        (rooted.linux-rooted-directory-result (& child))))))
                unit))
            unit)
          unit))
      status)))

(define (scenario-exclusive [root-path : (& root-path str)]) : i64
  (let
    [status : i64 10]
    (begin
      (with
        ([root-dir
            (rooted.linux-rooted-open-root
              root-path
              rooted.linux-rooted-never-cancelled)
            rooted.cleanup-linux-rooted-directory])
        (begin
          (if (rooted.linux-rooted-directory-open? (& root-dir))
            (with
              ([file
                  (rooted.linux-rooted-create-file
                    (& root-dir)
                    "winner.txt"
                    rooted.linux-rooted-never-cancelled)
                  rooted.cleanup-linux-rooted-file])
              (let
                [create-code : i64
                  (result-code (rooted.linux-rooted-file-result (& file)))]
                (begin
                  (cond
                    [(= create-code 3) (set! status 17)]
                    [(not (= create-code 0)) (set! status (+ 20 create-code))]
                    [else
                      (let
                        [contents : String "winner\n"]
                        [finished : rooted.FsLinuxRootedFinishResult
                          (finish-text! (&mut file) (& contents) false)]
                        (set!
                          status
                          (if (rooted.linux-rooted-finish-ok? finished)
                            42
                            (+ 40 (finish-code finished)))))])
                  unit)))
            unit)
          unit))
      status)))

(define (scenario-rename
  [root-path : (& root-path str)]
  [moved-path : (& moved-path str)]) : i64
  (let
    [status : i64 10]
    (begin
      (with
        ([root-dir
            (rooted.linux-rooted-open-root
              root-path
              rooted.linux-rooted-never-cancelled)
            rooted.cleanup-linux-rooted-directory])
        (begin
          (if (rooted.linux-rooted-directory-open? (& root-dir))
            (if (io.result-unit-ok? (fs.try-rename root-path moved-path))
              (with
                ([file
                    (rooted.linux-rooted-create-file
                      (& root-dir)
                      "after-rename.txt"
                      rooted.linux-rooted-never-cancelled)
                    rooted.cleanup-linux-rooted-file])
                (begin
                  (if (rooted.linux-rooted-file-open? (& file))
                    (let
                      [contents : String "retained descriptor\n"]
                      [finished : rooted.FsLinuxRootedFinishResult
                        (finish-text! (&mut file) (& contents) false)]
                      (set!
                        status
                        (if (rooted.linux-rooted-finish-ok? finished)
                          42
                          (+ 40 (finish-code finished)))))
                    (set!
                      status
                      (+
                        20
                        (result-code (rooted.linux-rooted-file-result (& file))))))
                  unit))
              (set! status 11))
            unit)
          unit))
      status)))

(define (scenario-child-rename [root-path : (& root-path str)]) : i64
  (let
    [status : i64 10]
    (begin
      (with
        ([root-dir
            (rooted.linux-rooted-open-root
              root-path
              rooted.linux-rooted-never-cancelled)
            rooted.cleanup-linux-rooted-directory])
        (begin
          (if (rooted.linux-rooted-directory-open? (& root-dir))
            (with
              ([child
                  (rooted.linux-rooted-create-directory
                    (& root-dir)
                    "child-before"
                    rooted.linux-rooted-never-cancelled)
                  rooted.cleanup-linux-rooted-directory])
              (if (rooted.linux-rooted-directory-open? (& child))
                (let
                  [old-path : String (fs.path-join root-path "child-before")]
                  [new-path : String (fs.path-join root-path "child-after")]
                  (if (io.result-unit-ok?
                    (fs.try-rename (& old-path) (& new-path)))
                    (with
                      ([file
                          (rooted.linux-rooted-create-file
                            (& child)
                            "after-child-rename.txt"
                            rooted.linux-rooted-never-cancelled)
                          rooted.cleanup-linux-rooted-file])
                      (if (rooted.linux-rooted-file-open? (& file))
                        (let
                          [contents : String "retained child descriptor\n"]
                          [finished : rooted.FsLinuxRootedFinishResult
                            (finish-text! (&mut file) (& contents) false)]
                          (set!
                            status
                            (if (rooted.linux-rooted-finish-ok? finished)
                              42
                              (+ 50 (finish-code finished)))))
                        (set!
                          status
                          (+
                            30
                            (result-code
                              (rooted.linux-rooted-file-result (& file)))))))
                    (set! status 12)))
                (set!
                  status
                  (+
                    20
                    (result-code
                      (rooted.linux-rooted-directory-result (& child)))))))
            unit)
          unit))
      status)))

(define (scenario-symlink [root-path : (& root-path str)]) : i64
  (let
    [status : i64 10]
    (begin
      (with
        ([root-dir
            (rooted.linux-rooted-open-root
              root-path
              rooted.linux-rooted-never-cancelled)
            rooted.cleanup-linux-rooted-directory])
        (begin
          (if (rooted.linux-rooted-directory-open? (& root-dir))
            (with
              ([file
                  (rooted.linux-rooted-create-file
                    (& root-dir)
                    "link"
                    rooted.linux-rooted-never-cancelled)
                  rooted.cleanup-linux-rooted-file])
              (with
                ([directory
                    (rooted.linux-rooted-create-directory
                      (& root-dir)
                      "link"
                      rooted.linux-rooted-never-cancelled)
                    rooted.cleanup-linux-rooted-directory])
                (begin
                  (set!
                    status
                    (if (and
                      (=
                        (result-code (rooted.linux-rooted-file-result (& file)))
                        3)
                      (=
                        (result-code
                          (rooted.linux-rooted-directory-result (& directory)))
                        3))
                      42
                      20))
                  unit)))
            unit)
          unit))
      status)))

(define (scenario-root-symlink [root-path : (& root-path str)]) : i64
  (with
    ([root-dir
        (rooted.linux-rooted-open-root
          root-path
          rooted.linux-rooted-never-cancelled)
        rooted.cleanup-linux-rooted-directory])
    (let
      [code : i64
        (result-code (rooted.linux-rooted-directory-result (& root-dir)))]
      (if (and
        (not (rooted.linux-rooted-directory-open? (& root-dir)))
        (or (= code 4) (= code 5)))
        42
        (+ 20 code)))))

(define (scenario-race [root-path : (& root-path str)]) : i64
  (let
    [status : i64 10]
    (begin
      (with
        ([root-dir
            (rooted.linux-rooted-open-root
              root-path
              rooted.linux-rooted-never-cancelled)
            rooted.cleanup-linux-rooted-directory])
        (begin
          (if (rooted.linux-rooted-directory-open? (& root-dir))
            (begin
              (rooted.linux-rooted-test-reset!)
              (rooted.linux-rooted-test-enable-mkdir-race!)
              (with
                ([directory
                    (rooted.linux-rooted-create-directory
                      (& root-dir)
                      "race-child"
                      rooted.linux-rooted-never-cancelled)
                    rooted.cleanup-linux-rooted-directory])
                (let
                  [code : i64
                    (result-code
                      (rooted.linux-rooted-directory-result (& directory)))]
                  (begin
                    (set!
                      status
                      (if (and
                        (rooted.linux-rooted-test-mkdir-race-ok?)
                        (or (= code 4) (= code 5)))
                        42
                        (+ 20 code)))
                    (rooted.linux-rooted-test-reset!)
                    unit))))
            unit)
          unit))
      status)))

(define (scenario-mount-race [root-path : (& root-path str)]) : i64
  (let
    [status : i64 10]
    (begin
      (with
        ([root-dir
            (rooted.linux-rooted-open-root
              root-path
              rooted.linux-rooted-never-cancelled)
            rooted.cleanup-linux-rooted-directory])
        (begin
          (if (rooted.linux-rooted-directory-open? (& root-dir))
            (begin
              (rooted.linux-rooted-test-reset!)
              (rooted.linux-rooted-test-set-after-mkdir-pause-ms! 5000)
              (with
                ([directory
                    (rooted.linux-rooted-create-directory
                      (& root-dir)
                      "mount-child"
                      rooted.linux-rooted-never-cancelled)
                    rooted.cleanup-linux-rooted-directory])
                (begin
                  (set!
                    status
                    (if (=
                      (result-code
                        (rooted.linux-rooted-directory-result (& directory)))
                      4)
                      42
                      20))
                  (rooted.linux-rooted-test-reset!)
                  unit)))
            unit)
          unit))
      status)))

(define (fault-short-write
  [root-dir : (& root-dir rooted.FsLinuxRootedDirectory)]) : i64
  (with
    ([file
        (rooted.linux-rooted-create-file
          root-dir
          "short-write.txt"
          rooted.linux-rooted-never-cancelled)
        rooted.cleanup-linux-rooted-file])
    (if (not (rooted.linux-rooted-file-open? (& file)))
      1
      (let
        [contents : String "abcdef"]
        (begin
          (rooted.linux-rooted-test-reset!)
          (rooted.linux-rooted-test-set-write-max! 2)
          (let
            [finished : rooted.FsLinuxRootedFinishResult
              (finish-text! (&mut file) (& contents) false)]
            (if (and
              (rooted.linux-rooted-finish-ok? finished)
              (=
                (rooted.linux-rooted-test-call-count
                  rooted.fs-linux-rooted-syscall-kind-write)
                3)
              (=
                (rooted.linux-rooted-test-call-count
                  rooted.fs-linux-rooted-syscall-kind-close)
                1))
              0
              2)))))))

(define (fault-write-eintr
  [root-dir : (& root-dir rooted.FsLinuxRootedDirectory)]) : i64
  (with
    ([file
        (rooted.linux-rooted-create-file
          root-dir
          "write-eintr.txt"
          rooted.linux-rooted-never-cancelled)
        rooted.cleanup-linux-rooted-file])
    (let
      [contents : String "retry"]
      (begin
        (rooted.linux-rooted-test-reset!)
        (rooted.linux-rooted-test-fail-on!
          rooted.fs-linux-rooted-syscall-kind-write
          1
          4)
        (let
          [finished : rooted.FsLinuxRootedFinishResult
            (finish-text! (&mut file) (& contents) false)]
          (if (and
            (rooted.linux-rooted-finish-ok? finished)
            (=
              (rooted.linux-rooted-test-call-count
                rooted.fs-linux-rooted-syscall-kind-write)
              2))
            0
            3))))))

(define (fault-zero-write
  [root-dir : (& root-dir rooted.FsLinuxRootedDirectory)]) : i64
  (with
    ([file
        (rooted.linux-rooted-create-file
          root-dir
          "zero-write.txt"
          rooted.linux-rooted-never-cancelled)
        rooted.cleanup-linux-rooted-file])
    (let
      [contents : String "reject zero"]
      (begin
        (rooted.linux-rooted-test-reset!)
        (rooted.linux-rooted-test-fail-on!
          rooted.fs-linux-rooted-syscall-kind-write
          1
          0)
        (let
          [finished : rooted.FsLinuxRootedFinishResult
            (finish-text! (&mut file) (& contents) false)]
          (if (and
            (= (finish-code finished) 1000)
            (=
              (rooted.linux-rooted-test-call-count
                rooted.fs-linux-rooted-syscall-kind-close)
              1))
            0
            4))))))

(define (fault-mode-eintr
  [root-dir : (& root-dir rooted.FsLinuxRootedDirectory)]) : i64
  (with
    ([file
        (rooted.linux-rooted-create-file
          root-dir
          "mode-eintr.txt"
          rooted.linux-rooted-never-cancelled)
        rooted.cleanup-linux-rooted-file])
    (let
      [contents : String "mode"]
      (begin
        (rooted.linux-rooted-test-reset!)
        (rooted.linux-rooted-test-fail-on!
          rooted.fs-linux-rooted-syscall-kind-fchmod
          1
          4)
        (let
          [finished : rooted.FsLinuxRootedFinishResult
            (finish-text! (&mut file) (& contents) false)]
          (if (and
            (rooted.linux-rooted-finish-ok? finished)
            (=
              (rooted.linux-rooted-test-call-count
                rooted.fs-linux-rooted-syscall-kind-fchmod)
              2))
            0
            5))))))

(define (fault-flush-eintr
  [root-dir : (& root-dir rooted.FsLinuxRootedDirectory)]) : i64
  (with
    ([file
        (rooted.linux-rooted-create-file
          root-dir
          "flush-eintr.txt"
          rooted.linux-rooted-never-cancelled)
        rooted.cleanup-linux-rooted-file])
    (let
      [contents : String "flush"]
      (begin
        (rooted.linux-rooted-test-reset!)
        (rooted.linux-rooted-test-fail-on!
          rooted.fs-linux-rooted-syscall-kind-fsync
          1
          4)
        (let
          [finished : rooted.FsLinuxRootedFinishResult
            (finish-text! (&mut file) (& contents) true)]
          (if (and
            (rooted.linux-rooted-finish-ok? finished)
            (=
              (rooted.linux-rooted-test-call-count
                rooted.fs-linux-rooted-syscall-kind-fsync)
              2))
            0
            6))))))

(define (fault-close [root-dir : (& root-dir rooted.FsLinuxRootedDirectory)]) : i64
  (with
    ([file
        (rooted.linux-rooted-create-file
          root-dir
          "close-failure.txt"
          rooted.linux-rooted-never-cancelled)
        rooted.cleanup-linux-rooted-file])
    (let
      [contents : String "close"]
      (begin
        (rooted.linux-rooted-test-reset!)
        (rooted.linux-rooted-test-fail-on!
          rooted.fs-linux-rooted-syscall-kind-close
          1
          4)
        (let
          [finished : rooted.FsLinuxRootedFinishResult
            (finish-text! (&mut file) (& contents) false)]
          (if (and
            (= (finish-code finished) 13)
            (=
              (result-code (rooted.linux-rooted-file-close-result (& file)))
              13)
            (=
              (rooted.linux-rooted-test-call-count
                rooted.fs-linux-rooted-syscall-kind-close)
              1))
            0
            7))))))

(define (fault-openat2-unsupported
  [root-dir : (& root-dir rooted.FsLinuxRootedDirectory)]) : i64
  (begin
    (rooted.linux-rooted-test-reset!)
    (rooted.linux-rooted-test-fail-on!
      rooted.fs-linux-rooted-syscall-kind-openat2
      1
      38)
    (with
      ([file
          (rooted.linux-rooted-create-file
            root-dir
            "unsupported-file.txt"
            rooted.linux-rooted-never-cancelled)
          rooted.cleanup-linux-rooted-file])
      (if (and
        (= (result-code (rooted.linux-rooted-file-result (& file))) 7)
        (=
          (rooted.linux-rooted-test-call-count
            rooted.fs-linux-rooted-syscall-kind-openat2)
          1)
        (=
          (rooted.linux-rooted-test-call-count
            rooted.fs-linux-rooted-syscall-kind-openat)
          0)
        (=
          (rooted.linux-rooted-test-call-count
            rooted.fs-linux-rooted-syscall-kind-close)
          0))
        0
        8))))

(define (fault-directory-reacquire-unsupported
  [root-dir : (& root-dir rooted.FsLinuxRootedDirectory)]) : i64
  (begin
    (rooted.linux-rooted-test-reset!)
    (rooted.linux-rooted-test-fail-on!
      rooted.fs-linux-rooted-syscall-kind-openat2
      1
      38)
    (with
      ([directory
          (rooted.linux-rooted-create-directory
            root-dir
            "unsupported-directory"
            rooted.linux-rooted-never-cancelled)
          rooted.cleanup-linux-rooted-directory])
      (if (and
        (= (result-code (rooted.linux-rooted-directory-result (& directory))) 7)
        (=
          (rooted.linux-rooted-test-call-count
            rooted.fs-linux-rooted-syscall-kind-mkdirat)
          1)
        (=
          (rooted.linux-rooted-test-call-count
            rooted.fs-linux-rooted-syscall-kind-openat2)
          1)
        (=
          (rooted.linux-rooted-test-call-count
            rooted.fs-linux-rooted-syscall-kind-openat)
          0)
        (=
          (rooted.linux-rooted-test-call-count
            rooted.fs-linux-rooted-syscall-kind-close)
          0))
        0
        9))))

(define (fault-directory-mode
  [root-dir : (& root-dir rooted.FsLinuxRootedDirectory)]) : i64
  (begin
    (rooted.linux-rooted-test-reset!)
    (rooted.linux-rooted-test-fail-on!
      rooted.fs-linux-rooted-syscall-kind-fchmod
      1
      5)
    (with
      ([directory
          (rooted.linux-rooted-create-directory
            root-dir
            "directory-mode-failure"
            rooted.linux-rooted-never-cancelled)
          rooted.cleanup-linux-rooted-directory])
      (if (and
        (=
          (result-code (rooted.linux-rooted-directory-result (& directory)))
          11)
        (=
          (result-code
            (rooted.linux-rooted-directory-close-result (& directory)))
          0)
        (=
          (rooted.linux-rooted-test-call-count
            rooted.fs-linux-rooted-syscall-kind-fchmod)
          1)
        (=
          (rooted.linux-rooted-test-call-count
            rooted.fs-linux-rooted-syscall-kind-close)
          1))
        0
        10))))

(define (fault-post-open
  [root-dir : (& root-dir rooted.FsLinuxRootedDirectory)]) : i64
  (begin
    (rooted.linux-rooted-test-reset!)
    (rooted.linux-rooted-test-fail-on!
      rooted.fs-linux-rooted-syscall-kind-fstat
      1
      5)
    (with
      ([file
          (rooted.linux-rooted-create-file
            root-dir
            "post-open-failure.txt"
            rooted.linux-rooted-never-cancelled)
          rooted.cleanup-linux-rooted-file])
      (if (and
        (= (result-code (rooted.linux-rooted-file-result (& file))) 8)
        (= (result-code (rooted.linux-rooted-file-close-result (& file))) 0)
        (=
          (rooted.linux-rooted-test-call-count
            rooted.fs-linux-rooted-syscall-kind-openat2)
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
        11))))

(define (fault-cancel-after-open
  [root-dir : (& root-dir rooted.FsLinuxRootedDirectory)]) : i64
  (begin
    (rooted.linux-rooted-test-reset!)
    (set! cancel-calls 0)
    (with
      ([file
          (rooted.linux-rooted-create-file
            root-dir
            "cancel-after-open.txt"
            cancel-on-second)
          rooted.cleanup-linux-rooted-file])
      (if (and
        (= (result-code (rooted.linux-rooted-file-result (& file))) 9)
        (= (result-code (rooted.linux-rooted-file-close-result (& file))) 0)
        (=
          (rooted.linux-rooted-test-call-count
            rooted.fs-linux-rooted-syscall-kind-close)
          1))
        0
        12))))

(define (fault-cancel-write
  [root-dir : (& root-dir rooted.FsLinuxRootedDirectory)]) : i64
  (with
    ([file
        (rooted.linux-rooted-create-file
          root-dir
          "cancel-write.txt"
          rooted.linux-rooted-never-cancelled)
        rooted.cleanup-linux-rooted-file])
    (let
      [contents : String "cancel"]
      (begin
        (rooted.linux-rooted-test-reset!)
        (let
          [finished : rooted.FsLinuxRootedFinishResult
            (finish-text-with-cancel! (&mut file) (& contents) cancel-now)]
          (if (and
            (= (finish-code finished) 900)
            (=
              (rooted.linux-rooted-test-call-count
                rooted.fs-linux-rooted-syscall-kind-write)
              0)
            (=
              (rooted.linux-rooted-test-call-count
                rooted.fs-linux-rooted-syscall-kind-close)
              1))
            0
            13))))))

(define (fault-lexical-cleanup
  [root-dir : (& root-dir rooted.FsLinuxRootedDirectory)]) : i64
  (begin
    (rooted.linux-rooted-test-reset!)
    (with
      ([file
          (rooted.linux-rooted-create-file
            root-dir
            "lexical-cleanup.txt"
            rooted.linux-rooted-never-cancelled)
          rooted.cleanup-linux-rooted-file])
      unit)
    (if (=
      (rooted.linux-rooted-test-call-count
        rooted.fs-linux-rooted-syscall-kind-close)
      1)
      0
      14)))

(define (fault-explicit-directory-close
  [root-dir : (& root-dir rooted.FsLinuxRootedDirectory)]) : i64
  (with
    ([directory
        (rooted.linux-rooted-create-directory
          root-dir
          "explicit-close-dir"
          rooted.linux-rooted-never-cancelled)
        rooted.cleanup-linux-rooted-directory])
    (begin
      (rooted.linux-rooted-test-reset!)
      (rooted.linux-rooted-test-fail-on!
        rooted.fs-linux-rooted-syscall-kind-close
        1
        4)
      (let
        [first : rooted.FsLinuxRootedResult
          (rooted.linux-rooted-directory-close! (&mut directory))]
        [second : rooted.FsLinuxRootedResult
          (rooted.linux-rooted-directory-close! (&mut directory))]
        (if (and
          (= (result-code first) 13)
          (= (result-code second) 14)
          (=
            (result-code
              (rooted.linux-rooted-directory-close-result (& directory)))
            13)
          (=
            (rooted.linux-rooted-test-call-count
              rooted.fs-linux-rooted-syscall-kind-close)
            1))
          0
          15)))))

(define (scenario-faults [root-path : (& root-path str)]) : i64
  (with
    ([root-dir
        (rooted.linux-rooted-open-root
          root-path
          rooted.linux-rooted-never-cancelled)
        rooted.cleanup-linux-rooted-directory])
    (if (not (rooted.linux-rooted-directory-open? (& root-dir)))
      10
      (let
        [result : i64 (fault-short-write (& root-dir))]
        (begin
          (if (= result 0)
            (set! result (fault-write-eintr (& root-dir)))
            unit)
          (if (= result 0)
            (set! result (fault-zero-write (& root-dir)))
            unit)
          (if (= result 0)
            (set! result (fault-mode-eintr (& root-dir)))
            unit)
          (if (= result 0)
            (set! result (fault-flush-eintr (& root-dir)))
            unit)
          (if (= result 0)
            (set! result (fault-close (& root-dir)))
            unit)
          (if (= result 0)
            (set! result (fault-openat2-unsupported (& root-dir)))
            unit)
          (if (= result 0)
            (set! result (fault-directory-reacquire-unsupported (& root-dir)))
            unit)
          (if (= result 0)
            (set! result (fault-directory-mode (& root-dir)))
            unit)
          (if (= result 0)
            (set! result (fault-post-open (& root-dir)))
            unit)
          (if (= result 0)
            (set! result (fault-cancel-after-open (& root-dir)))
            unit)
          (if (= result 0)
            (set! result (fault-cancel-write (& root-dir)))
            unit)
          (if (= result 0)
            (set! result (fault-lexical-cleanup (& root-dir)))
            unit)
          (if (= result 0)
            (set! result (fault-explicit-directory-close (& root-dir)))
            unit)
          (rooted.linux-rooted-test-reset!)
          (if (= result 0)
            42
            (+ 100 result)))))))

(define (main) : i64
  (if (< (io.arg-count) 3)
    2
    (let
      [scenario : String (io.arg 1)]
      [root-path : String (io.arg 2)]
      (cond
        [(string.eq (& scenario) "happy") (scenario-happy (& root-path))]
        [(string.eq (& scenario) "exclusive")
          (scenario-exclusive (& root-path))]
        [(string.eq (& scenario) "rename")
          (if (< (io.arg-count) 4)
            3
            (let
              [moved-path : String (io.arg 3)]
              (scenario-rename (& root-path) (& moved-path))))]
        [(string.eq (& scenario) "child-rename")
          (scenario-child-rename (& root-path))]
        [(string.eq (& scenario) "symlink") (scenario-symlink (& root-path))]
        [(string.eq (& scenario) "root-symlink")
          (scenario-root-symlink (& root-path))]
        [(string.eq (& scenario) "race") (scenario-race (& root-path))]
        [(string.eq (& scenario) "mount-race")
          (scenario-mount-race (& root-path))]
        [(string.eq (& scenario) "faults") (scenario-faults (& root-path))]
        [else 4]))))