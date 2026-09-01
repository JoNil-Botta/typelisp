;; Rooted directory capabilities own cleanup and cannot be copied or moved out
;; of their lexical cleanup scope.
(import stdlib.fs_rooted_linux as rooted)

(define (main) : i64
  (with
    ([directory
        (rooted.linux-rooted-failed-directory rooted.LinuxRootedIoFailure)
        rooted.cleanup-linux-rooted-directory])
    (with ([_copy directory rooted.cleanup-linux-rooted-directory]) 42)))