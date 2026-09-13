;; Safe callers cannot reposition a raw descriptor through the rooted seam.
(import stdlib.fs_rooted_linux as rooted)

(define (main) : i64
  (rooted.linux-rooted-raw-rewind 0))