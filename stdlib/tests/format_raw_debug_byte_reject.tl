;; Check-only: never execute these deliberately invalid raw ranges (#7945).
(import stdlib.format)

(define (main) : i64
  (begin
    (format.format-debug-write-byte!
      (ptr-null : (MutPtr u8))
      0
      (cast 65 : u8)
      0)
    42))