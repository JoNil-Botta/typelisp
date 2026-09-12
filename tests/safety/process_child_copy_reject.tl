;; Cleanup-owning process capabilities cannot be copied or moved twice.
(import stdlib.process)

(define (consume [_child : process.ProcessChild]) : unit
  unit)

(define (main) : i64
  (with
    ([child (process.ProcessChild (box 0)) process.cleanup-process-child])
    (begin
      (consume child)
      (consume child)
      0)))