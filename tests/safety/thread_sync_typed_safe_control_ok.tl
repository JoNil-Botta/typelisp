;; Checked typed task/channel/mutex operations remain callable without unsafe.
(import stdlib.thread)
(import stdlib.sync)
(import (thread.handle i64) as thread_i64)
(import (sync.channel i64) as channel_i64)
(import (sync.mutex i64) as mutex_i64)

(define (spawn-typed) : thread_i64.SpawnResult
  (thread_i64.spawn
    (lambda () : i64
      42)))

(define (channel-typed) : channel_i64.CreateResult
  (channel_i64.create 1))

(define (mutex-typed) : mutex_i64.CreateResult
  (mutex_i64.create 0))

(define (main) : i64
  0)