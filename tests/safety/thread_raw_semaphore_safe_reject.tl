;; A record constructor cannot confer close authority over an OS handle.
(import stdlib.thread)

(define (main) : i64
  (if (thread.semaphore-close (thread.ThreadSemaphore 0))
    1
    0))