(extern (tl_thread_init) : i64 (:symbol "ordinary_host_function"))
(extern (unused) : unit (:symbol "tl_thread_init"))

(define (main) : i64
  (tl_thread_init))