(import "stdlib/arena.tl")

(import "stdlib/string.tl")

(extern tl_arena_poison_enable : (-> unit))

(defstruct PoisonPayload
  (label String)
  (value i64))

(define (main) : i64
  (let
    [outer : i64 (arena-current)]
    [scratch : i64 (arena-make)]
    (begin
      (tl_arena_poison_enable)
      (unsafe
        (arena-set! scratch))
      (let
        [source : PoisonPayload
          (PoisonPayload (string-append "poison" "ok") 34)]
        (begin
          (unsafe
            (arena-set! outer))
          (let
            [copy : PoisonPayload (clone source)]
            (begin
              (unsafe
                (arena-destroy scratch))
              (+
                (string-length (struct-get copy label))
                (struct-get copy value)))))))))