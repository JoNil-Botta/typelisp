(import stdlib.io)

(define (main) : i64
  (unsafe
    (comptime (offset-of (type io.FileHandle) id))))