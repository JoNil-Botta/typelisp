;; The raw `thread.spawn` adapter is unsafe: an atomic arena owner its entry
;; lambda captures stays usable, and the caller joins the thread before
;; releasing the owner.
(import stdlib.arena)
(import stdlib.thread)

(define (main) : i64
  (let
    [owner : arena.Arena (arena.make-atomic)]
    (match (unsafe
      (thread.spawn
        (lambda ([base : i64]) : i64
          (in-arena owner (+ base 2)))
        40))
      [(ThreadSpawnOk raw)
        (let
          [value : i64
            (thread.join-result-value-or
              (unsafe
                (thread.join raw))
              0)]
          [extra : i64 (in-arena owner 0)]
          (begin
            (arena.destroy-safe! owner)
            (+ value extra)))]
      [(ThreadSpawnErr _) 1])))