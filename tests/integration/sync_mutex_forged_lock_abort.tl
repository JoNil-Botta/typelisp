;; A mutex handle constructed in safe code names no registered mutex: lock
;; aborts (134) before touching any cell or semaphore (#7755).
(import stdlib.sync)
(import (sync.mutex i64) as mutex_i64)

(define (main) : i64
  (with
    ([forged (mutex_i64.empty) mutex_i64.release])
    (with
      ([guard (mutex_i64.lock (& forged)) mutex_i64.unlock])
      (mutex_i64.get guard))))