;; Check-only: safe code cannot release the environment mutation lock it does
;; not hold (#7658).
(import stdlib.env)

(define (main) : i64
  (begin
    (env.linux-unlock!)
    42))