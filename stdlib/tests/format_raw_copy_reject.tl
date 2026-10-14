;; Check-only: never execute these deliberately invalid raw ranges (#7945).
(import stdlib.format)

(define (main) : i64
  (begin
    (format.format-copy-rendered-range! "data" 0 (ptr-null : (MutPtr u8)) 0 4)
    42))