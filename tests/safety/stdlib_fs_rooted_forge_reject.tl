;; Safe code cannot forge a rooted directory capability (#9783).
(import stdlib.fs_rooted_linux as rooted)

(define (main) : i64
  (with
    ([directory
        (rooted.FsLinuxRootedDirectory
          (ptr-null : (MutPtr rooted.FsLinuxRootedHandleState)))
        rooted.cleanup-linux-rooted-directory])
    0))