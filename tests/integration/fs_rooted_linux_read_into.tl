;; Native contract coverage for caller-owned rooted Linux reads (#7653).
(import stdlib.byte_buf)
(import stdlib.fs_rooted_linux as rooted)
(import stdlib.io)

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

(define (cancel-after-first-read) : bool
  (>
    (rooted.linux-rooted-test-call-count
      rooted.fs-linux-rooted-syscall-kind-read)
    0))

(define (read-into
  [reader : (&mut reader rooted.FsLinuxRootedReadFile)]
  [buffer : (&mut buffer byte_buf.ByteBuf)]
  [count : i64]
  [cancel-check : (-> bool)]) : rooted.FsLinuxRootedReadIntoResult
  (let
    [view : (&mut buffer bytes) (byte_buf.as-mut-bytes buffer)]
    (rooted.linux-rooted-read-file-into! reader view count cancel-check)))

(define (read-result-is?
  [result : (& result rooted.FsLinuxRootedReadIntoResult)]
  [operation : i64]
  [count : i64]
  [eof : bool]
  [short : bool]) : bool
  (and
    (= (result-code (rooted.linux-rooted-read-into-operation result)) operation)
    (= (rooted.linux-rooted-read-into-ok? result) (= operation 0))
    (= (rooted.linux-rooted-read-into-count result) count)
    (= (rooted.linux-rooted-read-into-eof? result) eof)
    (= (rooted.linux-rooted-read-into-short? result) short)))

(define (byte-is?
  [buffer : (& buffer byte_buf.ByteBuf)]
  [index : i64]
  [expected : i64]) : bool
  (= (cast (byte_buf.ref buffer index) : i64) expected))

(define (sentinel-eight? [buffer : (& buffer byte_buf.ByteBuf)]) : bool
  (and
    (byte-is? buffer 0 46)
    (byte-is? buffer 1 46)
    (byte-is? buffer 2 46)
    (byte-is? buffer 3 46)
    (byte-is? buffer 4 46)
    (byte-is? buffer 5 46)
    (byte-is? buffer 6 46)
    (byte-is? buffer 7 46)))

(define (check-semantics
  [directory : (& directory rooted.FsLinuxRootedDirectory)]) : i64
  (with
    ([reader
        (rooted.linux-rooted-reopen-file
          directory
          "payload.txt"
          rooted.linux-rooted-never-cancelled)
        rooted.cleanup-linux-rooted-read-file])
    (if (not (rooted.linux-rooted-read-file-open? (& reader)))
      10
      (let
        [buffer : byte_buf.ByteBuf (byte_buf.from-string "........")]
        [status : i64 0]
        (begin
          (rooted.linux-rooted-test-reset!)
          (let
            [negative : rooted.FsLinuxRootedReadIntoResult
              (read-into
                (&mut reader)
                (&mut buffer)
                -1
                rooted.linux-rooted-never-cancelled)]
            [over-view : rooted.FsLinuxRootedReadIntoResult
              (read-into
                (&mut reader)
                (&mut buffer)
                9
                rooted.linux-rooted-never-cancelled)]
            [oversized : rooted.FsLinuxRootedReadIntoResult
              (read-into
                (&mut reader)
                (&mut buffer)
                1048577
                rooted.linux-rooted-never-cancelled)]
            [zero : rooted.FsLinuxRootedReadIntoResult
              (read-into
                (&mut reader)
                (&mut buffer)
                0
                rooted.linux-rooted-never-cancelled)]
            [cancelled : rooted.FsLinuxRootedReadIntoResult
              (read-into (&mut reader) (&mut buffer) 1 cancel-now)]
            (if (or
              (not (read-result-is? (& negative) 17 0 false false))
              (not (read-result-is? (& over-view) 17 0 false false))
              (not (read-result-is? (& oversized) 17 0 false false))
              (not (read-result-is? (& zero) 0 0 false false))
              (not (read-result-is? (& cancelled) 9 0 false false))
              (not
                (=
                  (rooted.linux-rooted-test-call-count
                    rooted.fs-linux-rooted-syscall-kind-read)
                  0))
              (not (sentinel-eight? (& buffer))))
              (set! status 11)
              unit))
          (rooted.linux-rooted-test-reset!)
          (rooted.linux-rooted-test-set-read-max! 3)
          (let
            [first : rooted.FsLinuxRootedReadIntoResult
              (read-into
                (&mut reader)
                (&mut buffer)
                7
                rooted.linux-rooted-never-cancelled)]
            (if (or
              (not (read-result-is? (& first) 0 3 false true))
              (not (byte-is? (& buffer) 0 112))
              (not (byte-is? (& buffer) 1 97))
              (not (byte-is? (& buffer) 2 121))
              (not (byte-is? (& buffer) 3 46)))
              (set! status 12)
              unit))
          (rooted.linux-rooted-test-reset!)
          (let
            [second : rooted.FsLinuxRootedReadIntoResult
              (read-into
                (&mut reader)
                (&mut buffer)
                4
                rooted.linux-rooted-never-cancelled)]
            (if (or
              (not (read-result-is? (& second) 0 4 false false))
              (not (byte-is? (& buffer) 0 108))
              (not (byte-is? (& buffer) 1 111))
              (not (byte-is? (& buffer) 2 97))
              (not (byte-is? (& buffer) 3 100))
              (not (byte-is? (& buffer) 4 46)))
              (set! status 13)
              unit))
          (let
            [eof-read : rooted.FsLinuxRootedReadIntoResult
              (read-into
                (&mut reader)
                (&mut buffer)
                8
                rooted.linux-rooted-never-cancelled)]
            (if (not (read-result-is? (& eof-read) 0 0 true false))
              (set! status 14)
              unit))
          (if (not
            (=
              (result-code (rooted.linux-rooted-read-file-close! (&mut reader)))
              0))
            (set! status 15)
            unit)
          (rooted.linux-rooted-test-reset!)
          (let
            [closed : rooted.FsLinuxRootedReadIntoResult
              (read-into
                (&mut reader)
                (&mut buffer)
                1
                rooted.linux-rooted-never-cancelled)]
            (if (or
              (not (read-result-is? (& closed) 14 0 false false))
              (not
                (=
                  (rooted.linux-rooted-test-call-count
                    rooted.fs-linux-rooted-syscall-kind-read)
                  0)))
              (set! status 16)
              unit))
          status)))))

(define (check-faults [directory : (& directory rooted.FsLinuxRootedDirectory)]) : i64
  (with
    ([reader
        (rooted.linux-rooted-reopen-file
          directory
          "payload.txt"
          rooted.linux-rooted-never-cancelled)
        rooted.cleanup-linux-rooted-read-file])
    (if (not (rooted.linux-rooted-read-file-open? (& reader)))
      20
      (let
        [buffer : byte_buf.ByteBuf (byte_buf.from-string "........")]
        [status : i64 0]
        (begin
          (rooted.linux-rooted-test-reset!)
          (rooted.linux-rooted-test-fail-on!
            rooted.fs-linux-rooted-syscall-kind-read
            1
            5)
          (let
            [failed : rooted.FsLinuxRootedReadIntoResult
              (read-into
                (&mut reader)
                (&mut buffer)
                7
                rooted.linux-rooted-never-cancelled)]
            (if (or
              (not (read-result-is? (& failed) 19 0 false false))
              (not (sentinel-eight? (& buffer))))
              (set! status 21)
              unit))
          (rooted.linux-rooted-test-reset!)
          (rooted.linux-rooted-test-fail-on!
            rooted.fs-linux-rooted-syscall-kind-read
            1
            4)
          (let
            [cancelled : rooted.FsLinuxRootedReadIntoResult
              (read-into (&mut reader) (&mut buffer) 7 cancel-after-first-read)]
            (if (or
              (not (read-result-is? (& cancelled) 9 0 false false))
              (not
                (=
                  (rooted.linux-rooted-test-call-count
                    rooted.fs-linux-rooted-syscall-kind-read)
                  1))
              (not (sentinel-eight? (& buffer))))
              (set! status 22)
              unit))
          (rooted.linux-rooted-test-reset!)
          (rooted.linux-rooted-test-fail-on!
            rooted.fs-linux-rooted-syscall-kind-read
            1
            4)
          (let
            [retried : rooted.FsLinuxRootedReadIntoResult
              (read-into
                (&mut reader)
                (&mut buffer)
                7
                rooted.linux-rooted-never-cancelled)]
            (if (or
              (not (read-result-is? (& retried) 0 7 false false))
              (not
                (=
                  (rooted.linux-rooted-test-call-count
                    rooted.fs-linux-rooted-syscall-kind-read)
                  2))
              (not (byte-is? (& buffer) 0 112))
              (not (byte-is? (& buffer) 6 100))
              (not (byte-is? (& buffer) 7 46)))
              (set! status 23)
              unit))
          status)))))

(define (main) : i64
  (if (< (io.arg-count) 2)
    2
    (let
      [root-path : String (io.arg 1)]
      (with
        ([root
            (rooted.linux-rooted-open-root
              (& root-path)
              rooted.linux-rooted-never-cancelled)
            rooted.cleanup-linux-rooted-directory])
        (if (not (rooted.linux-rooted-directory-open? (& root)))
          3
          (let
            [create-result : rooted.FsLinuxRootedResult
              (create-text (& root) "payload.txt" "payload")]
            (if (not (rooted.linux-rooted-result-ok? create-result))
              4
              (let
                [semantics : i64 (check-semantics (& root))]
                (if (not (= semantics 0))
                  semantics
                  (let
                    [faults : i64 (check-faults (& root))]
                    (if (= faults 0)
                      42
                      faults)))))))))))