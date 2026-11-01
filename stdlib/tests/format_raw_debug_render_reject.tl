;; Check-only: never execute these deliberately invalid raw ranges (#7945).
(import stdlib.format)

(define (main) : i64
  (begin
    (format.format-debug-bytes-core
      (ptr-null : (Ptr u8))
      1
      (cast 0 : u8)
      false
      (cast 34 : u8))
    42))