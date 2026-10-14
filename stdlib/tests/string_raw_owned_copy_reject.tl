;; Check-only: never execute these deliberately invalid raw ranges (#7945).
(import stdlib.string)

(define (main) : i64
  (begin
    (string.str-copy-owned-bytes-into "data" (ptr-null : (MutPtr u8)) 0 4)
    42))