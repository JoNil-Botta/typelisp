;; An atomic arena owner held in a struct is destroyed through its place:
;; the spawned worker that captured its allocation must be joined first.
(import stdlib.arena)
(import stdlib.thread)
(import (thread.handle i64) as thread_i64)
(import stdlib.string)

(defstruct BrandedAtomicPlaceOwner
  (:lifetimes owner)
  (arena (arena.Arena owner)))

(define (main) : i64
  (let
    [owner (arena.make-atomic)]
    [text (in-arena owner (string.append "atomic" "-owned"))]
    [state (BrandedAtomicPlaceOwner owner)]
    (match (thread_i64.spawn
      (lambda () : i64
        (string.string-length text)))
      [(thread_i64.I64SpawnErr _) 1]
      [(thread_i64.I64SpawnOk worker)
        (begin
          (arena.destroy-safe! state.arena)
          (match (thread_i64.join worker)
            [(thread_i64.I64JoinErr _) 2]
            [(thread_i64.I64JoinOk value) (+ value 30)]))])))