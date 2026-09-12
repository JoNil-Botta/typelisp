;; Public raw record construction cannot grant access to OS-backed ring cells.
(import stdlib.sync)

(define (main) : i64
  (match (sync.i64-channel-send (sync.SyncI64Channel 0 0 1 8 0 0 0) 1)
    [(sync.SyncI64ChannelSendOk) 1]
    [(sync.SyncI64ChannelSendErr _) 0]))