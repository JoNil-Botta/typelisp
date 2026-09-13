;; Cursor mutation requires the exclusive borrow of the acquired capability.
(import stdlib.fs_rooted_linux as rooted)

(define (rewind-shared [file : (& file rooted.FsLinuxRootedReadFile)]) : rooted.FsLinuxRootedResult
  (rooted.linux-rooted-read-file-rewind!
    file
    rooted.linux-rooted-never-cancelled))

(define (main) : i64
  0)