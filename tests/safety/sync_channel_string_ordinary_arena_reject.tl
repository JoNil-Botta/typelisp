(import stdlib.arena)
(import stdlib.sync)
(import stdlib.string)

(define (main) : i64
  (let
    [owner : arena.Arena (arena.make)]
    (match (sync.channel-string-create 1)
      [(sync.ChannelStringCreateErr _) 1]
      [(sync.ChannelStringCreateOk channel)
        (match (sync.channel-string-send
          channel
          (in-arena owner (string.append "not-" "spanning")))
          [(sync.ChannelStringSendOk) 42]
          [(sync.ChannelStringSendErr _) 2])])))
