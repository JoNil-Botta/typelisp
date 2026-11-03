(import stdlib.thread)

(define (worker [value : i64]) : i64
  value)

(define (main) : i64
  (match (unsafe
    (thread.spawn worker 42))
    [(thread.ThreadSpawnErr _) 42]
    [(thread.ThreadSpawnOk task)
      (unsafe
        (thread.join task))
      1]))