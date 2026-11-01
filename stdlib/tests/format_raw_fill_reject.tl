;; Check-only: never execute these deliberately invalid raw ranges (#7945).
(import stdlib.format)

(define (main) : i64
  (begin
    (format.format-write-fill! (ptr-null : (MutPtr u8)) 0 1 'a')
    42))