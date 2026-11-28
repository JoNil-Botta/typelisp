(import stdlib.sync)

(define (main) : i64
  (let
    [_channel : sync.SyncI64Channel
      (unsafe
        (sync.SyncI64Channel 0 0 1 8 0 0 0))]
    42))