;; Check-only: never execute these deliberately invalid raw ranges (#7945).
(import stdlib.string as text)

(define (main) : i64
  (begin
    (text.str-copy-borrowed-bytes-into "data" (ptr-null : (MutPtr u8)) 0 4)
    42))