(import stdlib.sync)

(define (main) : i64
  (match (sync.channel-i64-pair-create 1)
    [(sync.ChannelI64PairCreateErr _) 1]
    [(sync.ChannelI64PairCreateOk channel)
      (let
        [msg : sync.ChannelI64Pair (sync.ChannelI64Pair 20 22)]
        [sent : sync.ChannelI64PairSendResult
          (sync.channel-i64-pair-send channel msg)]
        [after : i64 (struct-get msg left)]
        (match sent
          [(sync.ChannelI64PairSendOk) after]
          [(sync.ChannelI64PairSendErr _) 2]))]))