(import stdlib.sync)
(import stdlib.string)

(define (main) : i64
  (match (sync.channel-string-create 1)
    [(sync.ChannelStringCreateErr _) 1]
    [(sync.ChannelStringCreateOk channel)
      (let
        [message : String (string.append "not-" "transferable")]
        (match (sync.channel-string-send channel message)
          [(sync.ChannelStringSendOk) 42]
          [(sync.ChannelStringSendErr _) 2]))]))
