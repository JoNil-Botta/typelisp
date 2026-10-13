;; Check-only: never execute these deliberately invalid raw ranges (#7945).
(import stdlib.string)

(define (main) : i64
  (begin
    (string.str-copy-bytes-into
      (ptr-null : (Ptr u8))
      (ptr-null : (MutPtr u8))
      4096
      64)
    42))