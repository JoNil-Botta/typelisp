(import stdlib.thread)
(import (thread.handle (type unit)) as thread_unit)

(define (thread-safe-unit-join-ok? [thread : thread_unit.Handle]) : bool
  (match (thread_unit.join thread)
    [(thread_unit.UnitJoinOk) true]
    [(thread_unit.UnitJoinErr _) false]))

(define (thread-safe-unit-run) : i64
  (let
    [base : i64 40]
    (match (thread_unit.spawn
      (lambda () : unit
        (if (= (+ base 2) 42)
          unit
          unit)))
      [(thread_unit.UnitSpawnErr _) 3]
      [(thread_unit.UnitSpawnOk worker)
        (if (thread-safe-unit-join-ok? worker)
          42
          4)])))

(define (main) : i64
  (thread-safe-unit-run))