;; Rooted capability state is intentionally opaque to safe callers even though
;; TypeLisp does not yet have module-private visibility.
(import stdlib.fs_rooted_linux as rooted)

(define (read-state [directory : (& directory rooted.FsLinuxRootedDirectory)]) : rooted.FsLinuxRootedHandleState
  (rooted.linux-rooted-state-read directory.state))

(define (main) : i64
  42)