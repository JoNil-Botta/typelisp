;; Closing a mutex revokes every handle: locking a retained alias afterwards
;; aborts (134) instead of touching the freed cell or semaphore (#7755).
(import stdlib.sync)
(import (sync.mutex i64) as mutex_i64)

(define (lock-after-close [mutex : (& mutex mutex_i64.Mutex)]) : i64
  (match (mutex_i64.share mutex)
    [(ShareErr) 1]
    [(Shared alias)
      (if (mutex_i64.close mutex)
        (with
          ([guard (mutex_i64.lock (& alias)) mutex_i64.unlock])
          (mutex_i64.get guard))
        2)]))

(define (main) : i64
  (match (mutex_i64.create 7)
    [(CreateErr _) 1]
    [(CreateOk mutex) (lock-after-close (& mutex))]))