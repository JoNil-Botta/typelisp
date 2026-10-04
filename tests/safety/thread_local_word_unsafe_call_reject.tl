(unsafe
  (extern (storage) : (MutPtr i64) (:symbol "tl_thread_local_word_addr")))

(define (main) : i64
  (storage)
  0)