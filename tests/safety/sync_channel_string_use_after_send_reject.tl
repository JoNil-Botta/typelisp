(import stdlib.arena)
(import stdlib.sync)
(import stdlib.string)

(define (main) : i64
  (let
    [owner : arena.Arena (arena.make-atomic)]
    (match (sync.channel-string-create 1)
      [(sync.ChannelStringCreateErr _) 1]
      [(sync.ChannelStringCreateOk channel)
        (let
          [message : String (in-arena owner (string.append "owned" "-message"))]
          [sent : sync.ChannelStringSendResult
            (sync.channel-string-send channel message)]
          [after : i64 (string-length message)]
          (match sent
            [(sync.ChannelStringSendOk) after]
            [(sync.ChannelStringSendErr _) 2]))])))
