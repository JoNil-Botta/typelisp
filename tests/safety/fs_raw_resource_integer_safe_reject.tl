;; An untyped integer cannot safely bypass host-handle ownership and state.
(import stdlib.fs)

(define (main) : i64
  (fs.file-lock-close-status -1))