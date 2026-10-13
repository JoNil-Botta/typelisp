;; Check-only: never execute these deliberately invalid raw ranges (#7945).
(import stdlib.string)

(define (main) : i64
  (begin
    (string.int->string-write-negative-digits! (ptr-null : (MutPtr u8)) 0 -1 1)
    42))