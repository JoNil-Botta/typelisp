(import stdlib.arena as real_arena)
;; Retained for #2454 path-import compatibility: the helper module name is a
;; shadowing fixture and does not map to this same-directory source path.
(import "thread_spawn_i64_shadowed_atomic_arena_lib.tl" module shadow_arena as arena)
(import stdlib.thread)
(import (thread.handle i64) as thread_i64)
(import stdlib.string)

(define (main) : i64
  (let
    [owner : real_arena.Arena (arena.make-atomic)]
    [text : String (in-arena owner (string.append "not" "atomic"))]
    (match (thread_i64.spawn
      (lambda () : i64
        (string.string-length text)))
      [(thread_i64.I64SpawnErr _) 1]
      [(thread_i64.I64SpawnOk thread)
        (match (thread_i64.join thread)
          [(thread_i64.I64JoinOk value) value]
          [(thread_i64.I64JoinErr _) 2])])))
