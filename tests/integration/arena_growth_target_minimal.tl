(import stdlib.arena)

;; The always-provided helper must link even when tl_alloc is not requested.
(define (main) : i64
  (let
    [root : i64
      (unsafe
        (arena.tl_arena_growth_target 0))]
    (if (and
      (!= root 0)
      (= (arena.tl_arena_current) 0)
      (=
        (unsafe
          (arena.tl_arena_growth_target root))
        root))
      42
      1)))