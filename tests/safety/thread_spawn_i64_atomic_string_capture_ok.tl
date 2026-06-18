(import "stdlib/arena.tl")
(import "stdlib/thread.tl")
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
    [owner : i64 (arena-make-atomic)]
    [message : AtomicThreadMessage
      (in-arena
        owner
        (AtomicThreadMessageText (AtomicThreadText (string-append "atom" "ic"))))]
    [spawn : ThreadI64SpawnResult
      (thread-spawn-i64
        (lambda () : i64
          (atomic-thread-message-score message)))]
    42))