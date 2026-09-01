;; Probe program for the no-libc/no-CRT CI guard (scripts/verify-no-libc.sh).
;; Exercises the runtime surface that historically reached into libc/CRT:
;; printing, float formatting, allocation, environment, filesystem, and file IO.
;; The guard builds this to a native binary and asserts it pulls in no C runtime.
(import stdlib.io)
(import stdlib.string)
(import stdlib.env)
(import stdlib.fs)
(import stdlib.byte_buf)
(import stdlib.crypto_random)

(define (main) : i64
  (let
    [name : String "PATH"]
    [exists : bool (io.file-exists? "tests/no-libc/probe.tl")]
    [cwd : String (fs.current-dir)]
    [empty-random : byte_buf.ByteBuf
      (byte_buf.from-array (__tl_make-array u8 0))]
    (begin
      (io.print-format "{}" "no-libc probe\n")
      (io.println "{}" 1.5)
      (io.print-format "{}" (string.int->string (+ 40 2)))
      (io.print-format "{}" "\n")
      (match (env.get (& name))
        [(EnvSomeString _) (io.print-format "{}" "have-path\n")]
        [(EnvNoString) (io.print-format "{}" "no-path\n")])
      (match (crypto_random.fill-random!
        (byte_buf.as-mut-bytes (&mut empty-random)))
        [(crypto_random.OkFillRandom)
          (if (and exists (> (string-length cwd) 0))
            0
            1)]
        [(crypto_random.ErrFillRandom _) 2]))))