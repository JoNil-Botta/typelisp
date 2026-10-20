(import stdlib.arena)

(cfg
  compiler-arena-debug
  (extern (tl_arena_debug_protect_never_reset [root : i64]) : unit))
(cfg
  compiler-arena-debug
  (extern (tl_arena_debug_retire_protected [root : i64]) : unit))

;; The always-provided helper must link even when tl_alloc is not requested.
(define (main) : i64
  (let
    [root : i64
      (unsafe
        (arena.tl_arena_growth_target 0))]
    [accepted : bool
      (and
        (!= root 0)
        (= (arena.tl_arena_current) 0)
        (=
          (unsafe
            (arena.tl_arena_growth_target root))
          root))]
    (cfg
      compiler-arena-debug
      (begin
        (tl_arena_debug_protect_never_reset root)
        (tl_arena_debug_retire_protected root)))
    (if accepted
      42
      1)))