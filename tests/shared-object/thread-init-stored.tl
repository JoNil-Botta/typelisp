(extern (initialize) : unit (:symbol "tl_thread_init"))

(define initializer : (-> unit)
  initialize)

(define (main) : i64
  (initializer)
  0)