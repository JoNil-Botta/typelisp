;; The first split redirects a kept read to the later split branch result.
;; Its unmatched appended edge must keep the loan of pair.right live.
(defstruct Pair
  (left i64)
  (right i64))

(define (split-chain [choose : bool]) : i64
  (let
    [pair : Pair (Pair 3 39)]
    [first : (& pair i64) (& pair.left)]
    [second : (& pair i64) (& pair.right)]
    (set!
      first
      (if choose
        second
        (& pair.left)))
    (let
      [kept : (& pair i64) first]
      (set! second (& pair.left))
      (set! pair.right 40)
      (+ (read-reference kept) (read-reference second)))))

(define (read-reference [view : (& value i64)]) : i64
  (deref view))

(define (main) : i64
  (split-chain true))