;; The rooted state cleanup hook is unsafe to call directly (#9783).
(import stdlib.fs_rooted_linux as rooted)

(define (main) : i64
  (rooted.linux-rooted-state-cleanup
    (ptr-null : (MutPtr rooted.FsLinuxRootedHandleState)))
  0)