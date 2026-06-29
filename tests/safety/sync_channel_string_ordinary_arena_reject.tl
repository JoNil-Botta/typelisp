(import stdlib.arena)
(import "stdlib/sync.tl")
(import "stdlib/string.tl")

(define (main) : i64
  (let
    [owner : arena.Arena (arena.make)]
    (match (channel-string-create 1)
      [(ChannelStringCreateErr _) 1]
      [(ChannelStringCreateOk channel)
        (match (channel-string-send
          channel
          (in-arena owner (append "not-" "spanning")))
          [(ChannelStringSendOk) 42]
          [(ChannelStringSendErr _) 2])])))