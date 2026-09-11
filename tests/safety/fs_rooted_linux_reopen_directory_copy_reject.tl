;; A directory returned by existing-child reopen owns cleanup and cannot be
;; copied or moved out of its lexical cleanup scope.
(import stdlib.fs_rooted_linux as rooted)

(define (main) : i64
  (with
    ([parent
        (rooted.linux-rooted-failed-directory rooted.LinuxRootedIoFailure)
        rooted.cleanup-linux-rooted-directory])
    (with
      ([child
          (rooted.linux-rooted-reopen-directory
            (& parent)
            "child"
            rooted.linux-rooted-never-cancelled)
          rooted.cleanup-linux-rooted-directory])
      (with ([_copy child rooted.cleanup-linux-rooted-directory]) 42))))