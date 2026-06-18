(import "stdlib/sync.tl")

(define (main) : i64
  (match (channel-i64-pair-create 1)
    [(ChannelI64PairCreateErr _) 1]
    [(ChannelI64PairCreateOk channel)
      (let
        [msg : ChannelI64Pair (ChannelI64Pair 20 22)]
        [sent : ChannelI64PairSendResult (channel-i64-pair-send channel msg)]
        [after : i64 (struct-get msg left)]
        (match sent
          [(ChannelI64PairSendOk) after]
          [(ChannelI64PairSendErr _) 2]))]))