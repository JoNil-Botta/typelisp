(import stdlib.sync)
(import "stdlib/string.tl")

(define (main) : i64
  (match (sync.channel-string-create 1)
    [(sync.ChannelStringCreateErr _) 1]
    [(sync.ChannelStringCreateOk channel)
      (let
        [message : String (append "not-" "transferable")]
        (match (sync.channel-string-send channel message)
          [(sync.ChannelStringSendOk) 42]
          [(sync.ChannelStringSendErr _) 2]))]))