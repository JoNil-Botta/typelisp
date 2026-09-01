(import stdlib.io)
(import stdlib.thread)

(define (backtrace-worker-leaf [value : i64]) : i64
  (if (= value 42)
    (io.panic "worker backtrace fixture")
    value))

(define (backtrace-worker [value : i64]) : i64
  (+ (backtrace-worker-leaf value) 1))

(define (main) : i64
  (match (thread.spawn backtrace-worker 42)
    [(ThreadSpawnErr _) 2]
    [(ThreadSpawnOk handle)
      (match (thread.join handle)
        [(ThreadJoinErr _) 3]
        [(ThreadJoinOk value) value])]))