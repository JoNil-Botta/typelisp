;; Rooted read capabilities own cleanup and cannot be copied or moved out of
;; their lexical cleanup scope.
(import stdlib.fs_rooted_linux as rooted)

(define (main) : i64
  (with
    ([reader
        (rooted.linux-rooted-failed-read-file rooted.LinuxRootedIoFailure)
        rooted.cleanup-linux-rooted-read-file])
    (with ([_copy reader rooted.cleanup-linux-rooted-read-file]) 42)))