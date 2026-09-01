;; Safe callers cannot bypass cleanup ownership and close an arbitrary raw fd.
(import stdlib.fs_rooted_linux as rooted)

(define (main) : i64
  (rooted.linux-rooted-raw-close 0))