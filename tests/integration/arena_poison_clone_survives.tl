(import stdlib.arena)
(import stdlib.clone)
(import stdlib.string)

(extern (tl_arena_poison_enable) : unit)

(defstruct PoisonPayload
  (label String)
  (value i64))

(clone.gen-clone PoisonPayload)

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
        [copy : PoisonPayload (clone.deep source)]
        (unsafe
          (arena.destroy scratch))
        (+ (string-length copy.label) copy.value)))))