;; The OS-handle adapter cannot become an ordinary callable by aliasing.
(import stdlib.thread)

(define (main) : i64
  (let
    [_close : (-> thread.ThreadSemaphore bool)
      (unsafe
        thread.semaphore-close)]
    0))