;; The raw send API requires unsafe even when passed an existing channel.
(import stdlib.sync)

(define (send [channel : sync.SyncI64Channel]) : i64
  (match (sync.i64-channel-send channel 1)
    [(sync.SyncI64ChannelSendOk) 1]
    [(sync.SyncI64ChannelSendErr _) 0]))

(define (main) : i64
  42)