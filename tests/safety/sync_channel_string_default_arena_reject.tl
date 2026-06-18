(import "stdlib/sync.tl")
(import "stdlib/string.tl")

(define (main) : i64
  (match (channel-string-create 1)
    [(ChannelStringCreateErr _) 1]
    [(ChannelStringCreateOk channel)
      (let
        [message : String (string-append "not-" "transferable")]
        (match (channel-string-send channel message)
          [(ChannelStringSendOk) 42]
          [(ChannelStringSendErr _) 2]))]))