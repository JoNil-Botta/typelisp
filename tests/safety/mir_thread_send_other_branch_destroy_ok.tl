;; Thread users are a flow fact: a destroy on the path that sent nothing is
;; accepted.
(import stdlib.arena)
(import stdlib.sync)
(import stdlib.string)

(define (main) : i64
  (let
    [owner : arena.Arena (arena.make-atomic)]
    [send? : bool false]
    (match (sync.channel-string-create 1)
      [(sync.ChannelStringCreateErr _) 1]
      [(sync.ChannelStringCreateOk channel)
        (if send?
          (begin
            (sync.channel-string-send
              channel
              (in-arena owner (string.append "owned" "-message")))
            0)
          (begin
            (arena.destroy-safe! owner)
            0))])))