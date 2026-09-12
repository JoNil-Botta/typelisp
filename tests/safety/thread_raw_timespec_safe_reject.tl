;; A caller can supply fewer than two i64 slots for the kernel timespec write.
(import stdlib.thread)

(define (main) : i64
  (let
    [short : (__tl_dyn-array i64) (__tl_make-array i64 0)]
    (thread.linux-monotonic-ms (&mut short))))