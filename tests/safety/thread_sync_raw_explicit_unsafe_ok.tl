;; Check-only: these dummy addresses/handles must never be executed. The
;; caller explicitly assumes extent, alignment, lifetime and close authority.
(import stdlib.thread)
(import stdlib.sync)
(import (sync.channel i64) as channel_i64)

(define (raw-effects [addr : i64] [handle : i64]) : i64
  (unsafe
    (begin
      (sync.atomic-i64-store! addr 0 1)
      (thread.semaphore-post (thread.ThreadSemaphore handle))
      (thread.semaphore-close (thread.ThreadSemaphore handle))
      (sync.atomic-i64-load addr 0))))

(define (reconstruct [words : (& words (__tl_dyn-array i64))]) : channel_i64.Channel
  (unsafe
    (channel_i64.load-raw words 0)))

(define (main) : i64
  0)