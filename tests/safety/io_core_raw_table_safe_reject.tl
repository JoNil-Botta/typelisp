;; Raw table extents, initialization, and indices are caller obligations.
(import stdlib.io_core)

(define (main) : i64
  (io_core.io-file-i64-ref (ptr-null : (MutPtr i64)) 0))