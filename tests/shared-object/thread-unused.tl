(import stdlib.thread as _)

(extern (initialize) : unit (:symbol "tl_thread_init"))

(define (spawn) : i64
  42)

(define (main) : i64
  (spawn))