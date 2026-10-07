;; A generated declaration cannot launder the entry into an ordinary
;; function value either (#7742). Check-only; never executed.
(import stdlib.thread)

(defmacro (emit-entry-alias) : Decls
  `(define (entry-alias) : (-> i64 i64)
    thread.thread-windows-entry))

(emit-entry-alias)

(define (main) : i64
  0)