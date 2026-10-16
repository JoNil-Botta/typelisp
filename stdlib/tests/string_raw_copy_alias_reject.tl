;; Check-only: never call an invalid raw range.
(import stdlib.string as text)

(define (main) : i64
  (text.str-copy-bytes-into (ptr-null : (Ptr u8)) (ptr-null : (MutPtr u8)) 0 1)
  42)