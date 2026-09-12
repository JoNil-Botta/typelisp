;; An integer address alone proves neither a live cell nor alignment.
(import stdlib.sync)

(define (main) : i64
  (sync.atomic-i64-load 0 0))