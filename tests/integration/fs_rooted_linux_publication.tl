;; Linux native coverage for rooted reopen, publication, exact cleanup, and
;; parent-directory durability.
(import stdlib.byte_buf)
(import stdlib.fs)
(import stdlib.fs_rooted_linux as rooted)
(import stdlib.io)
(import stdlib.hash)
(import stdlib.profile)
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
    [(rooted.LinuxRootedReadFailure) 19]))

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

(define (cancel-now) : bool
  true)

(define (check-reopen [directory : (& directory rooted.FsLinuxRootedDirectory)]) : i64
  (let
    [status : i64 0]
    (begin
      (if (not
        (= (result-code (create-text directory "payload.tmp" "payload")) 0))
        (set! status 1)
        unit)
      (if (= status 0)
        (with
          ([reader
              (rooted.linux-rooted-reopen-file
                directory
                "payload.tmp"
                rooted.linux-rooted-never-cancelled)
              rooted.cleanup-linux-rooted-read-file])
          (if (not (rooted.linux-rooted-read-file-open? (& reader)))
            (set!
              status
              (+
                10
                (result-code (rooted.linux-rooted-read-file-result (& reader)))))
            (let
              [metadata : rooted.FsLinuxRootedFileMetadata
                (rooted.linux-rooted-read-file-metadata
                  (& reader)
                  rooted.linux-rooted-never-cancelled)]
              (begin
                (if (or
                  (not
                    (=
                      (result-code
                        (rooted.linux-rooted-metadata-result metadata))
                      0))
                  (not (= (rooted.linux-rooted-metadata-length metadata) 7))
                  (not
                    (=
                      (result-code
                        (rooted.linux-rooted-read-file-check-length
                          (& reader)
                          7
                          rooted.linux-rooted-never-cancelled))
                      0))
                  (not
                    (=
                      (result-code
                        (rooted.linux-rooted-read-file-check-length
                          (& reader)
                          8
                          rooted.linux-rooted-never-cancelled))
                      18)))
                  (set! status 2)
                  unit)
                (rooted.linux-rooted-test-reset!)
                (let
                  [negative : rooted.FsLinuxRootedReadResult
                    (rooted.linux-rooted-read-file-chunk!
                      (&mut reader)
                      -1
                      rooted.linux-rooted-never-cancelled)]
                  [oversized : rooted.FsLinuxRootedReadResult
                    (rooted.linux-rooted-read-file-chunk!
                      (&mut reader)
                      1048577
                      rooted.linux-rooted-never-cancelled)]
                  [zero : rooted.FsLinuxRootedReadResult
                    (rooted.linux-rooted-read-file-chunk!
                      (&mut reader)
                      0
                      rooted.linux-rooted-never-cancelled)]
                  [cancelled : rooted.FsLinuxRootedReadResult
                    (rooted.linux-rooted-read-file-chunk!
                      (&mut reader)
                      1
                      cancel-now)]
                  (if (or
                    (not
                      (=
                        (result-code
                          (rooted.linux-rooted-read-operation (& negative)))
                        17))
                    (not
                      (=
                        (result-code
                          (rooted.linux-rooted-read-operation (& oversized)))
                        17))
                    (not
                      (=
                        (result-code
                          (rooted.linux-rooted-read-operation (& zero)))
                        0))
                    (rooted.linux-rooted-read-eof? (& zero))
                    (rooted.linux-rooted-read-short? (& zero))
                    (not
                      (=
                        (result-code
                          (rooted.linux-rooted-read-operation (& cancelled)))
                        9))
                    (not
                      (=
                        (rooted.linux-rooted-test-call-count
                          rooted.fs-linux-rooted-syscall-kind-read)
                        0)))
                    (set! status 8)
                    unit))
                (rooted.linux-rooted-test-reset!)
                (rooted.linux-rooted-test-set-read-max! 3)
                (let
                  [first : rooted.FsLinuxRootedReadResult
                    (rooted.linux-rooted-read-file-chunk!
                      (&mut reader)
                      7
                      rooted.linux-rooted-never-cancelled)]
                  [first-operation : i64
                    (result-code (rooted.linux-rooted-read-operation (& first)))]
                  [first-short : bool
                    (rooted.linux-rooted-read-short? (& first))]
                  [first-eof : bool (rooted.linux-rooted-read-eof? (& first))]
                  [first-text : String
                    (byte_buf.to-string (rooted.linux-rooted-read-bytes first))]
                  (if (or
                    (not (= first-operation 0))
                    (not first-short)
                    first-eof
                    (not (string.eq (& first-text) "pay")))
                    (set! status 3)
                    unit))
                (rooted.linux-rooted-test-reset!)
                (let
                  [second : rooted.FsLinuxRootedReadResult
                    (rooted.linux-rooted-read-file-chunk!
                      (&mut reader)
                      7
                      rooted.linux-rooted-never-cancelled)]
                  [second-operation : i64
                    (result-code
                      (rooted.linux-rooted-read-operation (& second)))]
                  [second-short : bool
                    (rooted.linux-rooted-read-short? (& second))]
                  [second-eof : bool (rooted.linux-rooted-read-eof? (& second))]
                  [second-text : String
                    (byte_buf.to-string (rooted.linux-rooted-read-bytes second))]
                  (if (or
                    (not (= second-operation 0))
                    (not second-short)
                    second-eof
                    (not (string.eq (& second-text) "load")))
                    (set! status 4)
                    unit))
                (let
                  [eof-read : rooted.FsLinuxRootedReadResult
                    (rooted.linux-rooted-read-file-chunk!
                      (&mut reader)
                      7
                      rooted.linux-rooted-never-cancelled)]
                  (if (or
                    (not
                      (=
                        (result-code
                          (rooted.linux-rooted-read-operation (& eof-read)))
                        0))
                    (not (rooted.linux-rooted-read-eof? (& eof-read)))
                    (rooted.linux-rooted-read-short? (& eof-read)))
                    (set! status 5)
                    unit))
                (if (not
                  (=
                    (result-code
                      (rooted.linux-rooted-read-file-close! (&mut reader)))
                    0))
                  (set! status 6)
                  unit)
                (if (not
                  (=
                    (result-code
                      (rooted.linux-rooted-read-file-close! (&mut reader)))
                    14))
                  (set! status 7)
                  unit)))))
        unit)
      (rooted.linux-rooted-test-reset!)
      status)))

(define (reopen-code
  [directory : (& directory rooted.FsLinuxRootedDirectory)]
  [component : (& component str)]) : i64
  (with
    ([reader
        (rooted.linux-rooted-reopen-file
          directory
          component
          rooted.linux-rooted-never-cancelled)
        rooted.cleanup-linux-rooted-read-file])
    (result-code (rooted.linux-rooted-read-file-result (& reader)))))

(define (scenario-publication
  [source-path : (& source-path str)]
  [destination-path : (& destination-path str)]) : i64
  (let
    [outcome : i64 10]
    (begin
      (with
        ([source
            (rooted.linux-rooted-open-root
              source-path
              rooted.linux-rooted-never-cancelled)
            rooted.cleanup-linux-rooted-directory])
        (with
          ([destination
              (rooted.linux-rooted-open-root
                destination-path
                rooted.linux-rooted-never-cancelled)
              rooted.cleanup-linux-rooted-directory])
          (begin
            (set!
              outcome
              (if (or
                (not (rooted.linux-rooted-directory-open? (& source)))
                (not (rooted.linux-rooted-directory-open? (& destination))))
                10
                (let
                  [status : i64 (check-reopen (& source))]
                  (begin
                    (if (and
                      (= status 0)
                      (not (= (reopen-code (& source) "directory-entry") 5)))
                      (set! status 20)
                      unit)
                    (if (and
                      (= status 0)
                      (not (= (reopen-code (& source) "symlink-entry") 4)))
                      (set! status 21)
                      unit)
                    (if (and
                      (= status 0)
                      (not (= (reopen-code (& source) "fifo-entry") 5)))
                      (set! status 22)
                      unit)
                    (if (and
                      (= status 0)
                      (not
                        (=
                          (result-code
                            (create-text
                              (& source)
                              "same-parent.tmp"
                              "same parent\n"))
                          0)))
                      (set! status 43)
                      unit)
                    (if (and
                      (= status 0)
                      (not
                        (=
                          (result-code
                            (rooted.linux-rooted-rename-replace
                              (& source)
                              "same-parent.tmp"
                              (& source)
                              "same-parent.txt"
                              rooted.linux-rooted-never-cancelled))
                          0)))
                      (set! status 44)
                      unit)
                    (if (and
                      (= status 0)
                      (not (= (reopen-code (& source) "same-parent.txt") 0)))
                      (set! status 45)
                      unit)
                    (if (and
                      (= status 0)
                      (not
                        (=
                          (result-code
                            (create-text (& source) "publish.tmp" "published\n"))
                          0)))
                      (set! status 23)
                      unit)
                    (if (and
                      (= status 0)
                      (not
                        (=
                          (result-code
                            (rooted.linux-rooted-rename-no-replace
                              (& source)
                              "publish.tmp"
                              (& destination)
                              "published.txt"
                              rooted.linux-rooted-never-cancelled))
                          0)))
                      (set! status 24)
                      unit)
                    (if (and
                      (= status 0)
                      (not
                        (=
                          (result-code
                            (create-text
                              (& source)
                              "collision.tmp"
                              "collision source\n"))
                          0)))
                      (set! status 25)
                      unit)
                    (if (and
                      (= status 0)
                      (not
                        (=
                          (result-code
                            (rooted.linux-rooted-rename-no-replace
                              (& source)
                              "collision.tmp"
                              (& destination)
                              "collision.txt"
                              rooted.linux-rooted-never-cancelled))
                          3)))
                      (set! status 26)
                      unit)
                    (if (and
                      (= status 0)
                      (not
                        (=
                          (result-code
                            (rooted.linux-rooted-rename-no-replace
                              (& source)
                              "collision.tmp"
                              (& destination)
                              "collision-dir"
                              rooted.linux-rooted-never-cancelled))
                          3)))
                      (set! status 46)
                      unit)
                    (if (and
                      (= status 0)
                      (not
                        (=
                          (result-code
                            (create-text
                              (& source)
                              "replace.tmp"
                              "replacement\n"))
                          0)))
                      (set! status 27)
                      unit)
                    (if (and
                      (= status 0)
                      (not
                        (=
                          (result-code
                            (rooted.linux-rooted-rename-no-replace
                              (& source)
                              "replace.tmp"
                              (& destination)
                              "replace-link"
                              rooted.linux-rooted-never-cancelled))
                          3)))
                      (set! status 47)
                      unit)
                    (if (and
                      (= status 0)
                      (not
                        (=
                          (result-code
                            (rooted.linux-rooted-rename-replace
                              (& source)
                              "replace.tmp"
                              (& destination)
                              "replace-link"
                              rooted.linux-rooted-never-cancelled))
                          0)))
                      (set! status 28)
                      unit)
                    (if (and
                      (= status 0)
                      (not
                        (=
                          (result-code
                            (create-text (& source) "remove.txt" "remove me\n"))
                          0)))
                      (set! status 29)
                      unit)
                    (if (and
                      (= status 0)
                      (not
                        (=
                          (result-code
                            (rooted.linux-rooted-unlink-entry
                              (& source)
                              "remove.txt"
                              rooted.linux-rooted-never-cancelled))
                          0)))
                      (set! status 30)
                      unit)
                    (if (and
                      (= status 0)
                      (not
                        (=
                          (result-code
                            (rooted.linux-rooted-unlink-entry
                              (& source)
                              "remove.txt"
                              rooted.linux-rooted-never-cancelled))
                          2)))
                      (set! status 48)
                      unit)
                    (if (and
                      (= status 0)
                      (not
                        (=
                          (result-code
                            (rooted.linux-rooted-unlink-entry
                              (& source)
                              "remove-link"
                              rooted.linux-rooted-never-cancelled))
                          0)))
                      (set! status 31)
                      unit)
                    (if (and
                      (= status 0)
                      (not
                        (=
                          (result-code
                            (rooted.linux-rooted-unlink-entry
                              (& source)
                              "directory-entry"
                              rooted.linux-rooted-never-cancelled))
                          5)))
                      (set! status 32)
                      unit)
                    (if (and
                      (= status 0)
                      (not
                        (=
                          (result-code
                            (rooted.linux-rooted-remove-empty-directory
                              (& source)
                              "empty-dir"
                              rooted.linux-rooted-never-cancelled))
                          0)))
                      (set! status 33)
                      unit)
                    (if (and
                      (= status 0)
                      (not
                        (=
                          (result-code
                            (rooted.linux-rooted-remove-empty-directory
                              (& source)
                              "empty-dir"
                              rooted.linux-rooted-never-cancelled))
                          2)))
                      (set! status 49)
                      unit)
                    (if (and
                      (= status 0)
                      (not
                        (=
                          (result-code
                            (rooted.linux-rooted-remove-empty-directory
                              (& source)
                              "nonempty"
                              rooted.linux-rooted-never-cancelled))
                          16)))
                      (set! status 34)
                      unit)
                    (if (and
                      (= status 0)
                      (not
                        (=
                          (result-code
                            (rooted.linux-rooted-remove-empty-directory
                              (& source)
                              "symlink-entry"
                              rooted.linux-rooted-never-cancelled))
                          5)))
                      (set! status 35)
                      unit)
                    (rooted.linux-rooted-test-reset!)
                    (if (or
                      (not
                        (=
                          (result-code
                            (rooted.linux-rooted-rename-replace
                              (& source)
                              "../escape"
                              (& destination)
                              "bad"
                              rooted.linux-rooted-never-cancelled))
                          1))
                      (not
                        (=
                          (rooted.linux-rooted-test-call-count
                            rooted.fs-linux-rooted-syscall-kind-renameat)
                          0)))
                      (set! status 36)
                      unit)
                    (rooted.linux-rooted-test-reset!)
                    (if (or
                      (not
                        (=
                          (result-code
                            (rooted.linux-rooted-rename-no-replace
                              (& source)
                              "collision.tmp"
                              (& destination)
                              "cancelled"
                              cancel-now))
                          9))
                      (not
                        (=
                          (rooted.linux-rooted-test-call-count
                            rooted.fs-linux-rooted-syscall-kind-renameat2)
                          0)))
                      (set! status 37)
                      unit)
                    (if (and
                      (= status 0)
                      (not
                        (=
                          (result-code
                            (rooted.linux-rooted-directory-flush
                              (& source)
                              rooted.linux-rooted-never-cancelled))
                          0)))
                      (set! status 38)
                      unit)
                    (if (and
                      (= status 0)
                      (not
                        (=
                          (result-code
                            (rooted.linux-rooted-directory-flush
                              (& destination)
                              rooted.linux-rooted-never-cancelled))
                          0)))
                      (set! status 39)
                      unit)
                    (rooted.linux-rooted-test-reset!)
                    (if (= status 0)
                      42
                      status)))))
            unit)))
      outcome)))

(define (scenario-renamed-parents
  [source-path : (& source-path str)]
  [destination-path : (& destination-path str)]
  [moved-source-path : (& moved-source-path str)]
  [moved-destination-path : (& moved-destination-path str)]) : i64
  (with
    ([source
        (rooted.linux-rooted-open-root
          source-path
          rooted.linux-rooted-never-cancelled)
        rooted.cleanup-linux-rooted-directory])
    (with
      ([destination
          (rooted.linux-rooted-open-root
            destination-path
            rooted.linux-rooted-never-cancelled)
          rooted.cleanup-linux-rooted-directory])
      (cond
        [(or
            (not (rooted.linux-rooted-directory-open? (& source)))
            (not (rooted.linux-rooted-directory-open? (& destination))))
          10]
        [(not
            (io.result-unit-ok? (fs.try-rename source-path moved-source-path)))
          11]
        [(not
            (io.result-unit-ok?
              (fs.try-rename destination-path moved-destination-path)))
          12]
        [else
          (let
            [create-result : rooted.FsLinuxRootedResult
              (create-text (& source) "renamed.tmp" "renamed parents\n")]
            (if (not (= (result-code create-result) 0))
              13
              (let
                [rename-result : rooted.FsLinuxRootedResult
                  (rooted.linux-rooted-rename-no-replace
                    (& source)
                    "renamed.tmp"
                    (& destination)
                    "renamed.txt"
                    rooted.linux-rooted-never-cancelled)]
                (if (not (= (result-code rename-result) 0))
                  14
                  (if (not
                    (=
                      (result-code
                        (rooted.linux-rooted-directory-flush
                          (& destination)
                          rooted.linux-rooted-never-cancelled))
                      0))
                    15
                    42)))))]))))

(define (scenario-faults [root-path : (& root-path str)]) : i64
  (with
    ([root
        (rooted.linux-rooted-open-root
          root-path
          rooted.linux-rooted-never-cancelled)
        rooted.cleanup-linux-rooted-directory])
    (if (not (rooted.linux-rooted-directory-open? (& root)))
      10
      (let
        [status : i64 0]
        (begin
          (if (not
            (=
              (result-code
                (create-text (& root) "read-fault.txt" "fault payload\n"))
              0))
            (set! status 20)
            unit)
          (if (not
            (=
              (result-code
                (create-text (& root) "rename-fault.tmp" "fault payload\n"))
              0))
            (set! status 21)
            unit)
          (if (not
            (=
              (result-code
                (create-text (& root) "noreplace-fault.tmp" "fault payload\n"))
              0))
            (set! status 22)
            unit)
          (if (not
            (=
              (result-code
                (create-text (& root) "unlink-fault.txt" "fault payload\n"))
              0))
            (set! status 23)
            unit)
          (rooted.linux-rooted-test-reset!)
          (rooted.linux-rooted-test-fail-on!
            rooted.fs-linux-rooted-syscall-kind-reopen
            1
            5)
          (with
            ([failed-reader
                (rooted.linux-rooted-reopen-file
                  (& root)
                  "read-fault.txt"
                  rooted.linux-rooted-never-cancelled)
                rooted.cleanup-linux-rooted-read-file])
            (if (or
              (not
                (=
                  (result-code
                    (rooted.linux-rooted-read-file-result (& failed-reader)))
                  8))
              (not
                (=
                  (rooted.linux-rooted-test-call-count
                    rooted.fs-linux-rooted-syscall-kind-reopen)
                  1))
              (not
                (=
                  (rooted.linux-rooted-test-call-count
                    rooted.fs-linux-rooted-syscall-kind-close)
                  0)))
              (set! status 24)
              unit))
          (rooted.linux-rooted-test-reset!)
          (with
            ([reader
                (rooted.linux-rooted-reopen-file
                  (& root)
                  "read-fault.txt"
                  rooted.linux-rooted-never-cancelled)
                rooted.cleanup-linux-rooted-read-file])
            (begin
              (rooted.linux-rooted-test-reset!)
              (rooted.linux-rooted-test-fail-on!
                rooted.fs-linux-rooted-syscall-kind-read
                1
                5)
              (let
                [read-result : rooted.FsLinuxRootedReadResult
                  (rooted.linux-rooted-read-file-chunk!
                    (&mut reader)
                    8
                    rooted.linux-rooted-never-cancelled)]
                (if (not
                  (=
                    (result-code
                      (rooted.linux-rooted-read-operation (& read-result)))
                    19))
                  (set! status 25)
                  unit))
              (rooted.linux-rooted-test-reset!)
              (rooted.linux-rooted-test-fail-on!
                rooted.fs-linux-rooted-syscall-kind-read
                1
                4)
              (let
                [retry-read : rooted.FsLinuxRootedReadResult
                  (rooted.linux-rooted-read-file-chunk!
                    (&mut reader)
                    8
                    rooted.linux-rooted-never-cancelled)]
                (if (or
                  (not
                    (=
                      (result-code
                        (rooted.linux-rooted-read-operation (& retry-read)))
                      0))
                  (not
                    (=
                      (rooted.linux-rooted-test-call-count
                        rooted.fs-linux-rooted-syscall-kind-read)
                      2)))
                  (set! status 33)
                  unit))
              (rooted.linux-rooted-test-reset!)
              (rooted.linux-rooted-test-fail-on!
                rooted.fs-linux-rooted-syscall-kind-close
                1
                5)
              (if (or
                (not
                  (=
                    (result-code
                      (rooted.linux-rooted-read-file-close! (&mut reader)))
                    13))
                (not
                  (=
                    (rooted.linux-rooted-test-call-count
                      rooted.fs-linux-rooted-syscall-kind-close)
                    1)))
                (set! status 26)
                unit)))
          (rooted.linux-rooted-test-reset!)
          (rooted.linux-rooted-test-fail-on!
            rooted.fs-linux-rooted-syscall-kind-renameat
            1
            18)
          (if (not
            (=
              (result-code
                (rooted.linux-rooted-rename-replace
                  (& root)
                  "rename-fault.tmp"
                  (& root)
                  "rename-fault.txt"
                  rooted.linux-rooted-never-cancelled))
              15))
            (set! status 27)
            unit)
          (rooted.linux-rooted-test-reset!)
          (rooted.linux-rooted-test-fail-on!
            rooted.fs-linux-rooted-syscall-kind-renameat2
            1
            38)
          (if (not
            (=
              (result-code
                (rooted.linux-rooted-rename-no-replace
                  (& root)
                  "noreplace-fault.tmp"
                  (& root)
                  "noreplace-fault.txt"
                  rooted.linux-rooted-never-cancelled))
              7))
            (set! status 28)
            unit)
          (rooted.linux-rooted-test-reset!)
          (rooted.linux-rooted-test-fail-on!
            rooted.fs-linux-rooted-syscall-kind-unlinkat
            1
            5)
          (if (not
            (=
              (result-code
                (rooted.linux-rooted-unlink-entry
                  (& root)
                  "unlink-fault.txt"
                  rooted.linux-rooted-never-cancelled))
              8))
            (set! status 29)
            unit)
          (rooted.linux-rooted-test-reset!)
          (rooted.linux-rooted-test-fail-on!
            rooted.fs-linux-rooted-syscall-kind-rmdirat
            1
            5)
          (if (not
            (=
              (result-code
                (rooted.linux-rooted-remove-empty-directory
                  (& root)
                  "rmdir-fault"
                  rooted.linux-rooted-never-cancelled))
              8))
            (set! status 30)
            unit)
          (rooted.linux-rooted-test-reset!)
          (rooted.linux-rooted-test-fail-on!
            rooted.fs-linux-rooted-syscall-kind-directory-fsync
            1
            4)
          (if (or
            (not
              (=
                (result-code
                  (rooted.linux-rooted-directory-flush
                    (& root)
                    rooted.linux-rooted-never-cancelled))
                0))
            (not
              (=
                (rooted.linux-rooted-test-call-count
                  rooted.fs-linux-rooted-syscall-kind-directory-fsync)
                2)))
            (set! status 31)
            unit)
          (rooted.linux-rooted-test-reset!)
          (rooted.linux-rooted-test-fail-on!
            rooted.fs-linux-rooted-syscall-kind-directory-fsync
            1
            5)
          (if (not
            (=
              (result-code
                (rooted.linux-rooted-directory-flush
                  (& root)
                  rooted.linux-rooted-never-cancelled))
              12))
            (set! status 32)
            unit)
          (rooted.linux-rooted-test-reset!)
          (if (= status 0)
            42
            status))))))

;; Cursor tests share publication's acquired-file helpers and typed outcomes.
(define (rewind-reader [reader : (&mut reader rooted.FsLinuxRootedReadFile)]) : bool
  (rooted.linux-rooted-result-ok?
    (rooted.linux-rooted-read-file-rewind!
      reader
      rooted.linux-rooted-never-cancelled)))

(define (read-text-is?
  [reader : (&mut reader rooted.FsLinuxRootedReadFile)]
  [count : i64]
  [expected : (& expected str)]) : bool
  (let
    [read : rooted.FsLinuxRootedReadResult
      (rooted.linux-rooted-read-file-chunk!
        reader
        count
        rooted.linux-rooted-never-cancelled)]
    [ok : bool
      (rooted.linux-rooted-result-ok?
        (rooted.linux-rooted-read-operation (& read)))]
    [eof : bool (rooted.linux-rooted-read-eof? (& read))]
    [text : String (byte_buf.to-string (rooted.linux-rooted-read-bytes read))]
    (and
      ok
      (= eof (= (string-length expected) 0))
      (string.eq (& text) expected))))

(define (read-payload-hash
  [reader : (&mut reader rooted.FsLinuxRootedReadFile)]) : i64
  (let
    [read : rooted.FsLinuxRootedReadResult
      (rooted.linux-rooted-read-file-chunk!
        reader
        8
        rooted.linux-rooted-never-cancelled)]
    [ok : bool
      (rooted.linux-rooted-result-ok?
        (rooted.linux-rooted-read-operation (& read)))]
    [text : String (byte_buf.to-string (rooted.linux-rooted-read-bytes read))]
    (if (and ok (string.eq (& text) "payload") (read-text-is? reader 1 ""))
      (hash.string-key (& text))
      -1)))

(define (rewind-allocation-free?
  [reader : (&mut reader rooted.FsLinuxRootedReadFile)]) : bool
  (begin
    (rooted.linux-rooted-test-reset!)
    (profile.alloc-reset-peak)
    (let
      [before-total : i64 (profile.alloc-total)]
      [before-live : i64 (profile.alloc-live)]
      [index : i64 0]
      [ok : bool true]
      (begin
        (while (< index 128)
          (begin
            (if (not (rewind-reader reader))
              (set! ok false)
              unit)
            (set! index (+ index 1))))
        (let
          [after-total : i64 (profile.alloc-total)]
          [after-live : i64 (profile.alloc-live)]
          [peak : i64 (profile.alloc-peak)]
          [kind : i64 1]
          (begin
            (while (< kind rooted.fs-linux-rooted-syscall-kind-lseek)
              (begin
                (if (not (= (rooted.linux-rooted-test-call-count kind) 0))
                  (set! ok false)
                  unit)
                (set! kind (+ kind 1))))
            (and
              ok
              (= after-total before-total)
              (= after-live before-live)
              (= peak before-live)
              (=
                (rooted.linux-rooted-test-call-count
                  rooted.fs-linux-rooted-syscall-kind-lseek)
                128))))))))

(define (rewind-basics [root : (& root rooted.FsLinuxRootedDirectory)]) : bool
  (with
    ([reader
        (rooted.linux-rooted-reopen-file
          root
          "payload"
          rooted.linux-rooted-never-cancelled)
        rooted.cleanup-linux-rooted-read-file])
    (and
      (rooted.linux-rooted-read-file-open? (& reader))
      (rewind-reader (&mut reader))
      (read-text-is? (&mut reader) 2 "pa")
      (rewind-reader (&mut reader))
      (= (read-payload-hash (&mut reader)) (hash.string-key "payload"))
      (rewind-reader (&mut reader))
      (= (read-payload-hash (&mut reader)) (hash.string-key "payload"))
      (rewind-allocation-free? (&mut reader))
      (read-text-is? (&mut reader) 8 "payload")
      (read-text-is? (&mut reader) 1 ""))))

(define (rewind-empty [root : (& root rooted.FsLinuxRootedDirectory)]) : bool
  (with
    ([reader
        (rooted.linux-rooted-reopen-file
          root
          "empty"
          rooted.linux-rooted-never-cancelled)
        rooted.cleanup-linux-rooted-read-file])
    (and
      (rooted.linux-rooted-read-file-open? (& reader))
      (rewind-reader (&mut reader))
      (read-text-is? (&mut reader) 1 "")
      (rewind-reader (&mut reader))
      (read-text-is? (&mut reader) 1 ""))))

(define (rewind-fault-is?
  [reader : (&mut reader rooted.FsLinuxRootedReadFile)]
  [injected : i64]
  [expected : i64]) : bool
  (begin
    (rooted.linux-rooted-test-reset!)
    (rooted.linux-rooted-test-fail-on!
      rooted.fs-linux-rooted-syscall-kind-lseek
      1
      injected)
    (let
      [code : i64
        (result-code
          (rooted.linux-rooted-read-file-rewind!
            reader
            rooted.linux-rooted-never-cancelled))]
      [calls : i64
        (rooted.linux-rooted-test-call-count
          rooted.fs-linux-rooted-syscall-kind-lseek)]
      (begin
        (rooted.linux-rooted-test-reset!)
        (and
          (= code expected)
          (= calls 1)
          (rooted.linux-rooted-read-file-open? reader)
          (rewind-reader reader)
          (read-text-is? reader 8 "payload"))))))

;; Poison only valid allocated state, retaining its descriptor for exact-once
;; cleanup. No arbitrary pointer or out-of-lifetime access is exercised.
(define (rewind-poisoned-live?
  [reader : (&mut reader rooted.FsLinuxRootedReadFile)]) : bool
  (unsafe
    (let
      [saved : rooted.FsLinuxRootedHandleState
        (rooted.linux-rooted-state-read reader.state)]
      (begin
        (rooted.linux-rooted-test-reset!)
        (rooted.linux-rooted-state-write!
          reader.state
          (rooted.FsLinuxRootedHandleState
            saved.fd
            rooted.LinuxRootedIoFailure
            saved.close))
        (let
          [code : i64
            (result-code
              (rooted.linux-rooted-read-file-rewind!
                reader
                rooted.linux-rooted-never-cancelled))]
          [calls : i64
            (rooted.linux-rooted-test-call-count
              rooted.fs-linux-rooted-syscall-kind-lseek)]
          (begin
            (rooted.linux-rooted-state-write! reader.state saved)
            (and (= code 14) (= calls 0) (rewind-reader reader))))))))

(define (rewind-faults [root : (& root rooted.FsLinuxRootedDirectory)]) : bool
  (with
    ([reader
        (rooted.linux-rooted-reopen-file
          root
          "payload"
          rooted.linux-rooted-never-cancelled)
        rooted.cleanup-linux-rooted-read-file])
    (and
      (rooted.linux-rooted-read-file-open? (& reader))
      (read-text-is? (&mut reader) 2 "pa")
      (begin
        (rooted.linux-rooted-test-reset!)
        (and
          (=
            (result-code
              (rooted.linux-rooted-read-file-rewind! (&mut reader) cancel-now))
            9)
          (=
            (rooted.linux-rooted-test-call-count
              rooted.fs-linux-rooted-syscall-kind-lseek)
            0)
          (read-text-is? (&mut reader) 8 "yload")))
      (rewind-fault-is? (&mut reader) 5 8)
      (rewind-fault-is? (&mut reader) 9 8)
      (rewind-fault-is? (&mut reader) 22 7)
      (rewind-fault-is? (&mut reader) 4 9)
      (rewind-fault-is? (&mut reader) -7 8)
      (rewind-poisoned-live? (&mut reader))
      (rooted.linux-rooted-result-ok?
        (rooted.linux-rooted-read-file-close! (&mut reader)))
      (begin
        (rooted.linux-rooted-test-reset!)
        (and
          (=
            (result-code
              (rooted.linux-rooted-read-file-rewind!
                (&mut reader)
                rooted.linux-rooted-never-cancelled))
            14)
          (=
            (rooted.linux-rooted-test-call-count
              rooted.fs-linux-rooted-syscall-kind-lseek)
            0)
          (=
            (rooted.linux-rooted-test-call-count
              rooted.fs-linux-rooted-syscall-kind-close)
            0))))))

(define (rewind-retained-identity
  [root : (& root rooted.FsLinuxRootedDirectory)]) : bool
  (with
    ([reader
        (rooted.linux-rooted-reopen-file
          root
          "payload"
          rooted.linux-rooted-never-cancelled)
        rooted.cleanup-linux-rooted-read-file])
    (and
      (rooted.linux-rooted-read-file-open? (& reader))
      (= (read-payload-hash (&mut reader)) (hash.string-key "payload"))
      (rooted.linux-rooted-result-ok?
        (rooted.linux-rooted-rename-replace
          root
          "payload"
          root
          "moved"
          rooted.linux-rooted-never-cancelled))
      (rooted.linux-rooted-result-ok?
        (create-text root "payload" "replacement"))
      (rewind-reader (&mut reader))
      (= (read-payload-hash (&mut reader)) (hash.string-key "payload"))
      (rooted.linux-rooted-result-ok?
        (rooted.linux-rooted-unlink-entry
          root
          "moved"
          rooted.linux-rooted-never-cancelled))
      (rewind-reader (&mut reader))
      (= (read-payload-hash (&mut reader)) (hash.string-key "payload"))
      (with
        ([replacement
            (rooted.linux-rooted-reopen-file
              root
              "payload"
              rooted.linux-rooted-never-cancelled)
            rooted.cleanup-linux-rooted-read-file])
        (read-text-is? (&mut replacement) 16 "replacement")))))

(define (scenario-rewind [root-path : (& root-path str)]) : i64
  (with
    ([root
        (rooted.linux-rooted-open-root
          root-path
          rooted.linux-rooted-never-cancelled)
        rooted.cleanup-linux-rooted-directory])
    (cond
      [(not (rooted.linux-rooted-directory-open? (& root))) 10]
      [(not
          (rooted.linux-rooted-result-ok?
            (create-text (& root) "payload" "payload")))
        11]
      [(not (rooted.linux-rooted-result-ok? (create-text (& root) "empty" "")))
        12]
      [(not (rewind-basics (& root))) 13]
      [(not (rewind-empty (& root))) 14]
      [(not (rewind-faults (& root))) 15]
      [(not (rewind-retained-identity (& root))) 16]
      [else 42])))

(define (main) : i64
  (if (< (io.arg-count) 3)
    2
    (let
      [scenario : String (io.arg 1)]
      [source-path : String (io.arg 2)]
      (cond
        [(string.eq (& scenario) "publication")
          (if (< (io.arg-count) 4)
            3
            (let
              [destination-path : String (io.arg 3)]
              (scenario-publication (& source-path) (& destination-path))))]
        [(string.eq (& scenario) "renamed-parents")
          (if (< (io.arg-count) 6)
            3
            (let
              [destination-path : String (io.arg 3)]
              [moved-source-path : String (io.arg 4)]
              [moved-destination-path : String (io.arg 5)]
              (scenario-renamed-parents
                (& source-path)
                (& destination-path)
                (& moved-source-path)
                (& moved-destination-path))))]
        [(string.eq (& scenario) "rewind") (scenario-rewind (& source-path))]
        [(string.eq (& scenario) "faults") (scenario-faults (& source-path))]
        [else 4]))))