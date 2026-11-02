;; Check-only: invalid pointer/range witnesses must never execute (#8915).
(import stdlib.string.int->string-write-byte!)

(define (main) : i64
  (begin
    (int->string-write-byte! (ptr-null : (MutPtr u8)) 0 65)
    42))