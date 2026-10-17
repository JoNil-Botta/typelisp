(import stdlib.arena)
(import stdlib.string)
(import stdlib.sync)

(define (main) : i64
  (let
    [owner (arena.make-atomic)]
    [phase (arena.phase owner)]
    (match (sync.channel-string-create 1)
      [(sync.ChannelStringCreateErr _) 1]
      [(sync.ChannelStringCreateOk channel)
        (let
          [text (in-arena phase (string.append "queued" "-phase"))]
          [sent (sync.channel-string-send channel text)]
          (arena.rewind-safe! phase)
          (match sent
            [(sync.ChannelStringSendOk) 42]
            [(sync.ChannelStringSendErr _) 2]))])))