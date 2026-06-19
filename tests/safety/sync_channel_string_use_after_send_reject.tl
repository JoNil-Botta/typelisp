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
          [message : String (in-arena owner (string-append "owned" "-message"))]
          [sent : ChannelStringSendResult (channel-string-send channel message)]
          [after : i64 (string-length message)]
          (match sent
            [(ChannelStringSendOk) after]
            [(ChannelStringSendErr _) 2]))])))