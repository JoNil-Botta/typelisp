;; Check-only: invalid pointer/range witnesses must never execute (#8915).
(import stdlib.string as s)

(define (main) : i64
  (let
    [writer s.int->string-write-negative-digits!]
    (writer (ptr-null : (MutPtr u8)) 0 -42 2)
    42))