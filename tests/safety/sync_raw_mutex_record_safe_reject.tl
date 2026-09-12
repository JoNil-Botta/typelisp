;; The non-generated mutex record is a raw integer-handle carrier.
(import stdlib.sync)

(define (main) : i64
  (let
    [_guard : sync.SyncI64MutexGuard
      (sync.i64-mutex-lock (sync.SyncI64Mutex 0 0 0))]
    0))