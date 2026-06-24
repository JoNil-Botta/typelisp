(import "stdlib/arena.tl")
(import "stdlib/sync.tl")
(import "stdlib/string.tl")

(define (main) : i64
  (let
    [owner : Arena (arena-make-atomic)]
    (match (channel-string-create 1)
      [(ChannelStringCreateErr _) 1]
      [(ChannelStringCreateOk channel)
        (match (channel-string-send
          channel
          (in-arena owner (string-append "owned" "-message")))
          [(ChannelStringSendOk) 42]
          [(ChannelStringSendErr _) 2])])))