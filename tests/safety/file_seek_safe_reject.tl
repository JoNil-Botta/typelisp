(import stdlib.io)

(define (seek [handle : io.FileHandle]) : io.ResultIoUnit
  (io.file-seek handle 0))

(define (main) : i64
  42)