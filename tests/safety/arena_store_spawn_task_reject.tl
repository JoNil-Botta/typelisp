;; #8681: a safe spawn runs its task under the worker's arena scope; a task
;; that stores an allocation into a global is checked at the spawn call.
(import stdlib.thread)

(define g : (Box i64)
  (box 0))

(define (main) : i64
  (match (thread.spawn-box-i64
    (lambda () : (Box i64)
      (set! g (box 41))
      (box 1)))
    [(thread.ThreadBoxI64SpawnErr _) 1]
    [(thread.ThreadBoxI64SpawnOk cell)
      (match (thread.join-box-i64 cell)
        [(thread.ThreadBoxI64JoinOk value) (+ (deref value) (deref g))]
        [(thread.ThreadBoxI64JoinErr _) 2])]))