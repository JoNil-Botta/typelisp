;; Minimal no-argv rooted create used to exercise Linux's direct-object-enabled
;; planner route. This semantic closure currently requires the documented
;; assembler fallback. The shell gate runs it from an isolated `root/`.
(import stdlib.byte_buf)
(import stdlib.fs_rooted_linux as rooted)
(import stdlib.string)

(define (write-failed? [result : rooted.FsLinuxRootedResult]) : bool
  (match result
    [(rooted.LinuxRootedWriteFailure) true]
    [_ false]))

(define (ok? [result : rooted.FsLinuxRootedResult]) : bool
  (match result
    [(rooted.LinuxRootedOk) true]
    [_ false]))

(define (main) : i64
  (let
    [status : i64 10]
    (begin
      (with
        ([root-dir
            (rooted.linux-rooted-open-root
              "root"
              rooted.linux-rooted-never-cancelled)
            rooted.cleanup-linux-rooted-directory])
        (begin
          (if (rooted.linux-rooted-directory-open? (& root-dir))
            (with
              ([file
                  (rooted.linux-rooted-create-file
                    (& root-dir)
                    "direct.txt"
                    rooted.linux-rooted-never-cancelled)
                  rooted.cleanup-linux-rooted-file])
              (begin
                (if (rooted.linux-rooted-file-open? (& file))
                  (let
                    [contents : String "direct object\n"]
                    [finished : rooted.FsLinuxRootedFinishResult
                      (rooted.linux-rooted-file-finish!
                        (&mut file)
                        (byte_buf.str-as-bytes (& contents))
                        (string-length (& contents))
                        rooted.LinuxRootedRegularFile
                        false
                        rooted.linux-rooted-never-cancelled)]
                    (set!
                      status
                      (if (rooted.linux-rooted-finish-ok? finished)
                        42
                        30)))
                  (set! status 20))
                unit))
            unit)
          unit))
      (if (= status 42)
        (begin
          (rooted.linux-rooted-test-reset!)
          (with
            ([root-dir
                (rooted.linux-rooted-open-root
                  "root"
                  rooted.linux-rooted-never-cancelled)
                rooted.cleanup-linux-rooted-directory])
            (with
              ([file
                  (rooted.linux-rooted-create-file
                    (& root-dir)
                    "injected-failure.txt"
                    rooted.linux-rooted-never-cancelled)
                  rooted.cleanup-linux-rooted-file])
              (if (rooted.linux-rooted-file-open? (& file))
                (let
                  [contents : String "must fail\n"]
                  (begin
                    (rooted.linux-rooted-test-reset!)
                    (rooted.linux-rooted-test-fail-on!
                      rooted.fs-linux-rooted-syscall-kind-write
                      1
                      5)
                    (let
                      [finished : rooted.FsLinuxRootedFinishResult
                        (rooted.linux-rooted-file-finish!
                          (&mut file)
                          (byte_buf.str-as-bytes (& contents))
                          (string-length (& contents))
                          rooted.LinuxRootedRegularFile
                          false
                          rooted.linux-rooted-never-cancelled)]
                      (set!
                        status
                        (if (and
                          (write-failed?
                            (rooted.linux-rooted-finish-operation finished))
                          (ok? (rooted.linux-rooted-finish-close finished))
                          (=
                            (rooted.linux-rooted-test-call-count
                              rooted.fs-linux-rooted-syscall-kind-close)
                            1))
                          42
                          31)))))
                (set! status 30))))
          (if (not
            (=
              (rooted.linux-rooted-test-call-count
                rooted.fs-linux-rooted-syscall-kind-close)
              2))
            (set! status 32)
            unit)
          (rooted.linux-rooted-test-reset!))
        unit)
      status)))