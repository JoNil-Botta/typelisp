;; Check-only: safe code cannot scan a caller-owned environment table (#7658).
(import stdlib.env)

(define (main) : i64
  (env.linux-nonmatching-count (ptr-null : (Ptr (Ptr u8))) "X"))