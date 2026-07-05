(import stdlib.arena)
(import stdlib.sync)
(import stdlib.string)

(define (main) : i64
  (let
    [owner : arena.Arena (arena.make-atomic)]
    (match (sync.channel-string-create 1)
      [(ChannelStringCreateErr _) 1]
      [(ChannelStringCreateOk channel)
        (let
          [message : String (in-arena owner (string.append "owned" "-message"))]
          [sent : ChannelStringSendResult
            (sync.channel-string-send channel message)]
          (begin
            (arena.destroy-safe! owner)
            (match sent
              [(ChannelStringSendOk) 42]
              [(ChannelStringSendErr _) 2])))])))