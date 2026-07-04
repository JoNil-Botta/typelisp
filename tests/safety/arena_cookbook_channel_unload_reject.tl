(import stdlib.arena)
(import stdlib.sync)
(import stdlib.string)

(define (main) : i64
  (let
    [level : arena.Arena (arena.make-atomic)]
    (match (sync.channel-string-create 1)
      [(sync.ChannelStringCreateErr _) 1]
      [(sync.ChannelStringCreateOk channel)
        (let
          [message : String (in-arena level (string.append "queued" "-event"))]
          [sent : sync.ChannelStringSendResult
            (sync.channel-string-send channel message)]
          (begin
            (arena.destroy-safe! level)
            (match sent
              [(sync.ChannelStringSendOk) 42]
              [(sync.ChannelStringSendErr _) 2])))])))