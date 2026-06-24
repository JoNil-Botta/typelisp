(import "thread_spawn_unrelated_dotted_spawn_lib.tl" module local.worker as worker)

(define (main) : i64
  (match (worker.spawn 41)
    [(worker.SpawnOk value) value]))