;; Sending an owner-tagged value on one path gives the atomic arena thread
;; users on the joined path: the destroy after the join is rejected.
(import stdlib.arena)
(import stdlib.sync)
(import stdlib.string)

(define (main) : i64
  (let
    [owner : arena.Arena (arena.make-atomic)]
    [send? : bool true]
    (match (sync.channel-string-create 1)
      [(sync.ChannelStringCreateErr _) 1]
      [(sync.ChannelStringCreateOk channel)
        (begin
          (if send?
            (begin
              (sync.channel-string-send
                channel
                (in-arena owner (string.append "owned" "-message")))
              unit)
            unit)
          (arena.destroy-safe! owner)
          0)])))