;; Retained for #2454 path-import compatibility: the helper module name is
;; intentionally dotted and does not map to this same-directory source path.
(import "thread_spawn_unrelated_dotted_spawn_lib.tl" module local.worker as worker)

(define (main) : i64
  (match (worker.spawn 41)
    [(worker.SpawnOk value) value]))