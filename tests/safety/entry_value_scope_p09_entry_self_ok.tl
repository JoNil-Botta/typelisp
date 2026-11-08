;; #9687: the entry module's own use of its values, seen from the entry module.
(define (helper) : i64
  40)

(define limit : i64
  2)

(defenum Color
  (Red)
  (Blue))

(define (main) : i64
  (match Red
    [(Red) (+ (helper) limit)]
    [_ 0]))