;; A scratch-body allocation passed by value to a callee that only reads it
;; (#8815 twin).
(import stdlib.string)

(define (measure [s : String]) : i64
  (string.string-length (& s)))

(define (main) : i64
  (+ (with-scratch (measure (string.int->string 1234567))) 35))