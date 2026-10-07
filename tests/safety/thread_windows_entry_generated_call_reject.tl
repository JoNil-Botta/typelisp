;; A generated safe call of the entry is rejected like a written one
;; (#7742). Check-only; never executed.
(import stdlib.thread)

(defmacro (emit-entry-call) : Decls
  `(define (entry-call) : i64
    (thread.thread-windows-entry 0)))

(emit-entry-call)

(define (main) : i64
  0)