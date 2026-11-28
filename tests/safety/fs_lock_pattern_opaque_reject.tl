(import stdlib.fs)

(define (accept [lock : fs.FsFileLock]) : i64
  (match lock
    [(fs.FsFileLock _) 42]))

(define (main) : i64
  42)