;; An array literal mixing a caller reference with a borrow of a local has the
;; local's lifetime, whichever element comes first: no element escapes as the
;; caller's.
; Must fail: the array's elements live as long as `z`.
(define (first-of [xs : (& a (Array i64 2))]) : (& a i64)
  (let
    [z : i64 0]
    [rs (array (& (array-ref xs 0)) (& z))]
    (array-ref rs 0)))

(define (main) : i64
  0)