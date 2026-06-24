(import "stdlib/thread.tl")
(import (thread-handle bool) as thread_bool)

(define (thread-safe-bool-join-value [thread : thread_bool.Handle]) : bool
  (match (thread_bool.join thread)
    [(thread_bool.BoolJoinOk value) value]
    [(thread_bool.BoolJoinErr _) false]))

(define (thread-safe-bool-run) : i64
  (let
    [base : i64 39]
    [enabled : bool true]
    (match (thread_bool.spawn
      (lambda () : bool
        (and enabled (= (+ base 3) 42))))
      [(thread_bool.BoolSpawnErr _) 1]
      [(thread_bool.BoolSpawnOk worker)
        (if (thread-safe-bool-join-value worker)
          42
          2)])))

(define (main) : i64
  (thread-safe-bool-run))