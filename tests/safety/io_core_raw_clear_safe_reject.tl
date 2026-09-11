;; A raw integer is not proof that a live owned handle-table slot exists.
(import stdlib.io_core)

(define (main) : unit
  (io_core.io-file-handle-clear! -1))