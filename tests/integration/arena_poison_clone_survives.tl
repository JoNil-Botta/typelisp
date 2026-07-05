(import stdlib.arena)
(import stdlib.string)

(extern (tl_arena_poison_enable) : unit)

(defstruct PoisonPayload
  (label String)
  (value i64))

(define (main) : i64
  (let
    [outer : arena.Arena (arena.current)]
    [scratch : arena.Arena (arena.make)]
    (begin
      (tl_arena_poison_enable)
      (unsafe
        (arena.set! scratch))
      (let
        [source : PoisonPayload
          (PoisonPayload (string.append "poison" "ok") 34)]
        (begin
          (unsafe
            (arena.set! outer))
          (let
            [copy : PoisonPayload (clone source)]
            (begin
              (unsafe
                (arena.destroy scratch))
              (+
                (string-length (struct-get copy label))
                (struct-get copy value)))))))))