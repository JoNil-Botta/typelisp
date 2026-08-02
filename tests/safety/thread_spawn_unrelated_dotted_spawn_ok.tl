;; Import the co-located worker helper through its dotted module identity.
(import thread_spawn_unrelated_dotted_spawn_lib as worker)

(define (main) : i64
  (match (worker.spawn 41)
    [(worker.SpawnOk value) value]))