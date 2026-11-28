(import stdlib.arena)
(import stdlib.crypto_sha256 as sha)
(import stdlib.fs)
(import stdlib.io)
(import stdlib.sync)

(defstruct Handles
  (arena arena.Arena)
  (mark arena.ArenaMark)
  (file io.FileHandle)
  (lock fs.FsFileLock)
  (channel sync.SyncI64Channel)
  (hash sha.Sha256State))

(define (store-handles [handles : Handles]) : (Array Handles 1)
  (array handles))

(define (main) : i64
  (if (and
    (= (comptime (size-of (type arena.Arena))) 8)
    (= (comptime (size-of (type arena.ArenaMark))) 8)
    (= (comptime (size-of (type io.FileHandle))) 8)
    (= (comptime (size-of (type fs.FsFileLock))) 8)
    (= (comptime (size-of (type sync.SyncI64Channel))) 56)
    (= (comptime (size-of (type sha.Sha256State))) 120))
    42
    1))