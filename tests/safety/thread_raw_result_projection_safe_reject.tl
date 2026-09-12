;; A raw spawn result does not make its native handle safe to expose.
(import stdlib.thread)

(define (main) : i64
  (let
    [result : thread.ThreadSpawnResult (thread.ThreadSpawnErr "no worker")]
    (thread.spawn-result-handle-or (& result) 0)))