(extern (initialize) : unit (:symbol "tl_thread_init"))

(define (start) : unit
  (initialize))

(define (main) : i64
  (start)
  0)