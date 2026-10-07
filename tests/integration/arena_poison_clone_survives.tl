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
    (tl_arena_poison_enable)
    (unsafe
      (arena.set! scratch))
    (let
      [source : PoisonPayload (PoisonPayload (string.append "poison" "ok") 34)]
      (unsafe
        (arena.set! outer))
      (let
        [copy : PoisonPayload (clone source)]
        (unsafe
          (arena.destroy scratch))
        (+ (string-length copy.label) copy.value)))))