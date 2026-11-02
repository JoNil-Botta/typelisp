;; Check-only: invalid pointer/range witnesses must never execute (#8915).
(import stdlib.string as s)

(define (main) : i64
  (begin
    (s.int->string-write-byte! (ptr-null : (MutPtr u8)) 0 65)
    42))