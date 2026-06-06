;; Probe program for the no-libc/no-CRT CI guard (scripts/verify-no-libc.sh).
;; Exercises the runtime surface that historically reached into libc/CRT:
;; printing, float formatting, allocation, environment, filesystem, and file IO.
;; The guard builds this to a native binary and asserts it pulls in no C runtime.
(import "../../stdlib/io.tl")

(import "../../stdlib/env.tl")

(import "../../stdlib/fs.tl")

(define (main) : i64
  (let
    [name : String "PATH"]
    [exists : bool (file-exists? "tests/no-libc/probe.tl")]
    [cwd : String (fs-current-dir)]
    (begin
      (print-string "no-libc probe\n")
      (print-float 1.5)
      (print-string (int->string (+ 40 2)))
      (print-string "\n")
      (match (env-get (& name))
        [(EnvSomeString _) (print-string "have-path\n")]
        [(EnvNoString) (print-string "no-path\n")])
      (if (and exists (> (string-length cwd) 0))
        0
        1))))