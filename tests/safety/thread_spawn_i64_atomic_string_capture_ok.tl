(import stdlib.arena)
(import stdlib.thread)
(import (thread.handle i64) as thread_i64)
(import "stdlib/string.tl")

(defstruct AtomicThreadText
  (text String))

(defenum AtomicThreadMessage
  (AtomicThreadMessageText AtomicThreadText)
  (AtomicThreadMessageNone))

(define (atomic-thread-message-score [message : AtomicThreadMessage]) : i64
  6)

(define (main) : i64
  (let
    [owner : arena.Arena (arena.make-atomic)]
    [message : AtomicThreadMessage
      (in-arena
        owner
        (AtomicThreadMessageText (AtomicThreadText (append "atom" "ic"))))]
    [spawn : thread_i64.SpawnResult
      (thread_i64.spawn
        (lambda () : i64
          (atomic-thread-message-score message)))]
    42))