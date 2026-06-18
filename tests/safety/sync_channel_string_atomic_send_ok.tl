(import "stdlib/arena.tl")
(import "stdlib/sync.tl")
(import "stdlib/string.tl")

(define (main) : i64
  (let
    [owner : i64 (arena-make-atomic)]
    (match (channel-string-create 1)
      [(ChannelStringCreateErr _) 1]
      [(ChannelStringCreateOk channel)
        (let
          [sent : ChannelStringSendResult
            (channel-string-send
              channel
              (in-arena owner (string-append "owned" "-message")))]
          (match sent
            [(ChannelStringSendOk) 42]
            [(ChannelStringSendErr _) 2]))])))