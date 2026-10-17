;; Check-only: never execute these deliberately invalid raw ranges (#7945).
(import stdlib.format)

(define (main) : i64
  (begin
    (format.format-debug-source-byte
      (ptr-null : (Ptr u8))
      0
      (cast 0 : u8)
      false)
    42))