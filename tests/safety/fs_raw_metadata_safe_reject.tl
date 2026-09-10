;; Raw metadata field reads require the caller to prove allocation extent,
;; layout, alignment, initialization, and lifetime.
(import stdlib.fs)

(define (main) : i64
  (fs.metadata-read-i64-at (ptr-null : (MutPtr u8)) 0))