;; Check-only: never execute these deliberately invalid raw ranges (#7945).
(import stdlib.string)

(define (main) : i64
  (begin
    (string.int->string-write-byte! (ptr-null : (MutPtr u8)) 0 65)
    42))