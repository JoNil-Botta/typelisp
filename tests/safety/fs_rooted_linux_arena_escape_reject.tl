;; Capability state allocated in a caller's lexical arena cannot outlive that
;; arena's reset; keep the cleanup owner inside the scope instead.
(import stdlib.fs_rooted_linux as rooted)

(define (escape) : rooted.FsLinuxRootedDirectory
  (with-arena
    scratch
    (rooted.linux-rooted-failed-directory rooted.LinuxRootedIoFailure)))

(define (main) : i64
  42)