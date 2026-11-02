;; Check-only: invalid pointer/range witnesses must never execute (#8915).
(import stdlib.string.int->string-write-negative-digits!)

(define (main) : i64
  (begin
    (int->string-write-negative-digits! (ptr-null : (MutPtr u8)) 0 -42 2)
    42))