;; Probe program for the no-libc/no-CRT CI guard (scripts/verify-no-libc.sh).
;; Exercises the runtime surface that historically reached into libc/CRT:
;; printing, float formatting, allocation, environment, filesystem, and file IO.
;; The guard builds this to a native binary and asserts it pulls in no C runtime.
(import stdlib.io)
(import stdlib.string)
(import stdlib.env)
(import stdlib.fs)

(define (main) : i64
  (let
    [name : String "PATH"]
    [exists : bool (io.file-exists? "tests/no-libc/probe.tl")]
    [cwd : String (fs.current-dir)]
    (begin
      (io.print-string "no-libc probe\n")
      (io.print-float 1.5)
      (io.print-string (string.int->string (+ 40 2)))
      (io.print-string "\n")
      (match (env.get (& name))
        [(EnvSomeString _) (io.print-string "have-path\n")]
        [(EnvNoString) (io.print-string "no-path\n")])
      (if (and exists (> (string-length cwd) 0))
        0
        1))))
